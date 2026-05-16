defmodule BotArmyGtd.Handlers.PlanHandler do
  @moduledoc """
  Handles goal and plan-related events for the GTD bot.

  This module processes incoming plan messages:
  - `gtd.goal.plan` - Decompose goal into tasks and create plan
  - `gtd.goal.status` - Get plan status
  - `gtd.goal.list` - List active plans
  - `gtd.goal.cancel` - Cancel a plan

  Each operation validates the input, performs the action, and publishes
  corresponding response events.

  ## Dependencies

  - `BotArmyGtd.PlanStore` - Persistent plan storage
  - `BotArmyGtd.NATS.Publisher` - Event publishing
  - `BotArmyRuntime.NATS.Publisher` - NATS request/reply for LLM calls
  """

  require Logger

  alias BotArmyCore.Tenant
  alias BotArmyGtd.{EventBuilder, NATS.Publisher, PlanStore, TaskStore}

  defp plan_store do
    Application.get_env(:bot_army_gtd, :plan_store, BotArmyGtd.PlanStore)
  end

  @doc """
  Handle goal decomposition request.

  Accepts a goal, optionally creates a plan, calls LLM to decompose,
  creates task records, and returns plan_id + tasks.

  Returns {:ok, plan_response} or {:error, reason}.
  """
  def handle_goal_plan(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    stamped_payload =
      Map.merge(payload, %{
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case validate_goal_plan_payload(stamped_payload) do
      :ok ->
        goal = payload["goal"]
        context = payload["context"] || %{}
        constraints = payload["constraints"] || %{}
        notify_via_subject = payload["notify_via_subject"]

        case create_plan_record(goal, context, constraints, tenant_id, user_id) do
          {:ok, plan} ->
            Logger.info("Plan created: plan_id=#{plan["id"]}, goal=#{goal}, event_id=#{event_id}")

            # Decompose goal into subtasks (for now, mock implementation)
            case decompose_goal(goal, context, constraints) do
              {:ok, subtasks} ->
                # Create Task records linked to plan
                case create_tasks_from_decomposition(plan["id"], subtasks, tenant_id, user_id) do
                  {:ok, tasks} ->
                    Logger.info(
                      "Plan decomposed: plan_id=#{plan["id"]}, task_count=#{length(tasks)}"
                    )

                    # Update plan to executing state
                    {:ok, _updated_plan} =
                      plan_store().update(tenant_id, plan["id"], %{"status" => "executing"})

                    # Notify user if notify_via_subject provided
                    if notify_via_subject do
                      notify_user(plan["id"], notify_via_subject, length(tasks))
                    end

                    # Publish event
                    publish_event(
                      "gtd.plan.created",
                      %{
                        "plan_id" => plan["id"],
                        "goal" => goal,
                        "task_count" => length(tasks),
                        "tasks" => tasks
                      },
                      event_id,
                      message,
                      tenant_id,
                      user_id
                    )

                    {:ok, %{"plan_id" => plan["id"], "tasks" => tasks}}

                  {:error, reason} ->
                    Logger.error("Failed to create plan tasks: #{inspect(reason)}")

                    publish_error(
                      event_id,
                      reason,
                      "Failed to create plan tasks",
                      tenant_id,
                      user_id
                    )

                    {:error, reason}
                end

              {:error, reason} ->
                Logger.error("Failed to decompose goal: #{inspect(reason)}")
                publish_error(event_id, reason, "Failed to decompose goal", tenant_id, user_id)
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create plan: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to create plan", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid goal plan payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid plan data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle goal status request.

  Returns current plan status and list of associated tasks.
  """
  def handle_goal_status(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_goal_status_payload(payload) do
      :ok ->
        plan_id = payload["plan_id"]

        case plan_store().get(tenant_id, plan_id) do
          {:ok, plan} ->
            response = %{
              "plan_id" => plan["id"],
              "goal" => plan["goal"],
              "status" => plan["status"],
              "completed_at" => plan["completed_at"],
              "created_at" => plan["inserted_at"]
            }

            Logger.info("Plan status retrieved: plan_id=#{plan_id}, status=#{plan["status"]}")

            {:ok, response}

          {:error, reason} ->
            Logger.error("Plan not found: #{plan_id}")
            publish_error(event_id, reason, "Plan not found", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid goal status payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid request data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle goal cancellation request.

  Cancels a plan and optionally cancels associated tasks.
  """
  def handle_goal_cancel(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_goal_cancel_payload(payload) do
      :ok ->
        plan_id = payload["plan_id"]
        reason = payload["reason"] || "User cancelled"

        case plan_store().get(tenant_id, plan_id) do
          {:ok, _plan} ->
            case plan_store().update(tenant_id, plan_id, %{
                   "status" => "cancelled",
                   "metadata" => %{"cancellation_reason" => reason}
                 }) do
              {:ok, updated_plan} ->
                Logger.info("Plan cancelled: plan_id=#{plan_id}, reason=#{reason}")

                publish_event(
                  "gtd.plan.cancelled",
                  %{"plan_id" => plan_id, "reason" => reason},
                  event_id,
                  message,
                  tenant_id,
                  user_id
                )

                {:ok, %{"plan_id" => plan_id, "status" => updated_plan["status"]}}

              {:error, reason} ->
                Logger.error("Failed to cancel plan: #{inspect(reason)}")
                publish_error(event_id, reason, "Failed to cancel plan", tenant_id, user_id)
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Plan not found: #{plan_id}")
            publish_error(event_id, reason, "Plan not found", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid goal cancel payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid request data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle goal list request.

  Lists active plans, optionally filtered by status.
  """
  def handle_goal_list(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    filter = payload["filter"] || "active"
    filters = if filter == "active", do: %{"status" => "executing"}, else: %{}

    case plan_store().list(tenant_id, filters) do
      {:ok, plans} ->
        Logger.info(
          "Plans listed: tenant_id=#{tenant_id}, filter=#{filter}, count=#{length(plans)}"
        )

        response = %{
          "filter" => filter,
          "plans" => plans
        }

        {:ok, response}

      {:error, reason} ->
        Logger.error("Failed to list plans: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to list plans", tenant_id, user_id)
        {:error, reason}
    end
  end

  # Private helpers

  defp validate_goal_plan_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "goal") do
      :ok
    end
  end

  defp validate_goal_plan_payload(_), do: {:error, :invalid_payload}

  defp validate_goal_status_payload(payload) when is_map(payload) do
    require_field(payload, "plan_id")
  end

  defp validate_goal_status_payload(_), do: {:error, :invalid_payload}

  defp validate_goal_cancel_payload(payload) when is_map(payload) do
    require_field(payload, "plan_id")
  end

  defp validate_goal_cancel_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp create_plan_record(goal, context, constraints, tenant_id, user_id) do
    plan_data = %{
      "goal" => goal,
      "context" => context,
      "constraints" => constraints,
      "status" => "planning",
      "user_id" => user_id,
      "tenant_id" => tenant_id
    }

    plan_store().create(plan_data)
  end

  @doc """
  Decompose a goal into ordered subtasks.

  For Phase 1, this is a basic implementation that returns hardcoded subtasks.
  In Phase 2, this will call the LLM bot to decompose dynamically.
  """
  defp decompose_goal(goal, _context, _constraints) do
    subtasks = [
      %{
        "order" => 1,
        "description" => "Analyze goal: #{goal}",
        "target_bot" => "gtd",
        "target_subject" => "gtd.task.create"
      },
      %{
        "order" => 2,
        "description" => "Execute goal: #{goal}",
        "target_bot" => "gtd",
        "target_subject" => "gtd.task.create"
      }
    ]

    {:ok, subtasks}
  end

  defp create_tasks_from_decomposition(plan_id, subtasks, tenant_id, user_id) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

    tasks =
      Enum.map(subtasks, fn subtask ->
        task_data = %{
          "title" => subtask["description"],
          "description" => "Auto-generated from plan",
          "status" => "active",
          "priority" => "normal",
          "source" => "plan_decomposition",
          "generated_by_ai" => true,
          "plan_id" => plan_id,
          "plan_order" => subtask["order"],
          "tenant_id" => tenant_id,
          "user_id" => user_id
        }

        case task_store.create(task_data) do
          {:ok, task} -> task
          {:error, _reason} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, tasks}
  end

  defp notify_user(plan_id, notify_via_subject, task_count) when is_binary(notify_via_subject) do
    # Publish notification event to the provided subject
    event_data = %{
      "subject" => notify_via_subject,
      "type" => "plan_created",
      "plan_id" => plan_id,
      "task_count" => task_count,
      "message" => "Plan created with #{task_count} tasks"
    }

    case Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("Notification sent to #{notify_via_subject}")

      :ok ->
        Logger.debug("Notification sent to #{notify_via_subject}")

      {:error, reason} ->
        Logger.error("Failed to send notification: #{inspect(reason)}")
    end
  end

  defp notify_user(_plan_id, _notify_via_subject, _task_count), do: :ok

  defp publish_event(event_type, payload, event_id, _original_message, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        event_type,
        Map.merge(payload, %{"triggered_by_event_id" => event_id}),
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published event: #{event_type}")
      :ok -> Logger.debug("Published event: #{event_type}")
      {:error, reason} -> Logger.error("Failed to publish event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published error event")
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end

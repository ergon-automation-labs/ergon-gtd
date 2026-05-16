defmodule BotArmyGtd.Handlers.NotificationHandler do
  @moduledoc """
  Handles notification events for plan-related failures and status updates.

  This module listens for plan-related events:
  - `events.gtd.plan.task_failed` - A task in a plan failed
  - `events.gtd.plan.completed` - A plan completed successfully

  Each event triggers creation of a notification through the notification router,
  with appropriate templates and user actions.

  ## Dependencies

  - `BotArmyGtd.PlanStore` - Plan data retrieval
  - `BotArmyGtd.TaskStore` - Task data retrieval
  - `BotArmyGtd.NATS.Publisher` - Notification publishing
  """

  require Logger
  alias BotArmyCore.Tenant
  alias BotArmyGtd.{EventBuilder, NATS.Publisher}

  defp plan_store do
    Application.get_env(:bot_army_gtd, :plan_store, BotArmyGtd.PlanStore)
  end

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle plan task failure event.

  Creates a notification when a task within a plan fails, allowing the user
  to decide whether to retry, skip, or abort the plan.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_task_failed(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_task_failed_payload(payload) do
      :ok ->
        process_task_failed(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid task_failed payload: #{inspect(reason)}")
    end
  end

  @doc """
  Handle plan completion event.

  Creates a notification when a plan completes successfully.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_plan_completed(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_plan_completed_payload(payload) do
      :ok ->
        process_plan_completed(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid plan_completed payload: #{inspect(reason)}")
    end
  end

  # Private functions

  defp validate_task_failed_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "plan_id"),
         :ok <- require_field(payload, "task_id") do
      :ok
    end
  end

  defp validate_task_failed_payload(_), do: {:error, :invalid_payload}

  defp validate_plan_completed_payload(payload) when is_map(payload) do
    require_field(payload, "plan_id")
  end

  defp validate_plan_completed_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_task_failed(payload, _event_id, tenant_id, user_id) do
    plan_id = payload["plan_id"]
    task_id = payload["task_id"]
    task_description = Map.get(payload, "task_description", "Unknown task")
    failure_reason = Map.get(payload, "failure_reason", "Unknown reason")

    Logger.info("Processing task failure in plan: plan_id=#{plan_id}, task_id=#{task_id}")

    case plan_store().get(tenant_id, plan_id) do
      {:ok, plan} ->
        create_task_failure_notification(
          plan,
          task_id,
          task_description,
          failure_reason,
          tenant_id,
          user_id
        )

      {:error, reason} ->
        Logger.warning("Failed to fetch plan #{plan_id}: #{inspect(reason)}")
    end

    :ok
  end

  defp process_plan_completed(payload, _event_id, tenant_id, user_id) do
    plan_id = payload["plan_id"]
    plan = Map.get(payload, "plan", %{})

    Logger.info("Processing plan completion: plan_id=#{plan_id}")

    create_plan_completion_notification(plan, tenant_id, user_id)

    :ok
  end

  defp create_task_failure_notification(
         plan,
         task_id,
         task_description,
         failure_reason,
         tenant_id,
         user_id
       ) do
    plan_id = plan["id"]

    # Find task order in plan for title
    task_order =
      case task_store().list_by_plan(tenant_id, plan_id) do
        {:ok, tasks} ->
          Enum.find_index(tasks, fn t -> t["id"] == task_id end)

        _ ->
          nil
      end

    step_number = if is_number(task_order), do: task_order + 1, else: "?"

    # Build notification payload
    notification = %{
      "title" => "Plan Step #{step_number} Failed",
      "body" => "Task '#{task_description}' failed. Reason: #{failure_reason}",
      "category" => "plan_failure",
      "priority" => "high",
      "actions" => [
        %{
          "id" => "retry",
          "label" => "Retry",
          "action" => "plan.task.retry"
        },
        %{
          "id" => "skip",
          "label" => "Skip Step",
          "action" => "plan.task.skip"
        },
        %{
          "id" => "abort",
          "label" => "Abort Plan",
          "action" => "plan.cancel"
        }
      ],
      "metadata" => %{
        "plan_id" => plan_id,
        "task_id" => task_id,
        "plan_goal" => Map.get(plan, "goal", ""),
        "plan_status_url" => "gtd.goal.status?plan_id=#{plan_id}"
      }
    }

    publish_notification(notification, tenant_id, user_id)
  end

  defp create_plan_completion_notification(plan, tenant_id, user_id) do
    plan_id = plan["id"]
    goal = Map.get(plan, "goal", "Your plan")

    notification = %{
      "title" => "Plan Completed!",
      "body" => "Your plan '#{goal}' has completed successfully.",
      "category" => "plan_completion",
      "priority" => "normal",
      "actions" => [
        %{
          "id" => "view",
          "label" => "View Plan",
          "action" => "plan.view"
        }
      ],
      "metadata" => %{
        "plan_id" => plan_id,
        "plan_status_url" => "gtd.goal.status?plan_id=#{plan_id}"
      }
    }

    publish_notification(notification, tenant_id, user_id)
  end

  defp publish_notification(notification_payload, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "notifications.create",
        notification_payload,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("Published notification: #{notification_payload["title"]}")

      {:error, reason} ->
        Logger.error("Failed to publish notification: #{inspect(reason)}")
    end
  end
end

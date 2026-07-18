defmodule BotArmyGtd.Adapters.PlanAdapter do
  @moduledoc """
  Intelligent plan adaptation when tasks fail.

  When a task in a plan fails, this adapter automatically replans the remaining
  steps using the LLM instead of just notifying the user. This enables the system
  to gracefully handle failures and recover by finding alternative approaches.

  ## Public API

  - `replan_on_failure(plan_id, failed_task_id, failure_reason, context)` → {:ok, new_tasks} or {:error, reason}

  ## Workflow

  1. Fetch the plan and all remaining tasks
  2. Build a replan prompt: "Step X failed (reason: <failure_reason>). Remaining tasks: [...]. Replan the rest."
  3. Call LLM to generate new subtasks
  4. Parse and validate new subtasks
  5. Create Task records for replanned steps
  6. Update original plan with new tasks
  7. Emit `events.gtd.plan.adapted` event
  8. Return {:ok, new_tasks} or {:error, reason}

  ## Error Handling

  Returns `{:error, reason}` for:
  - `:plan_not_found` - Plan does not exist
  - `:task_not_found` - Failed task does not exist
  - `:invalid_plan_status` - Plan is not in executing state
  - `:timeout` - LLM request timed out
  - `:parse_error` - Failed to parse LLM response
  - `:database_error` - Failed to create new tasks
  """

  require Logger

  alias BotArmyGtd.Decomposer

  @default_timeout_ms 15_000

  @doc """
  Automatically replan remaining tasks when one fails.

  Fetches the plan and remaining tasks, calls LLM to generate replacement steps,
  creates new Task records, and emits an adaptation event.

  ## Arguments

    * `plan_id` - UUID of the plan
    * `failed_task_id` - UUID of the failed task
    * `failure_reason` - String describing why the task failed
    * `context` - Optional map with additional context for replanning (user_id, tenant_id, etc.)

  ## Returns

    * `{:ok, new_tasks}` - List of newly created task maps
    * `{:error, reason}` - Error tuple with reason atom

  ## Examples

      {:ok, new_tasks} = PlanAdapter.replan_on_failure(
        plan_id,
        failed_task_id,
        "network timeout: could not connect to API",
        %{user_id: user_id, tenant_id: tenant_id}
      )

      {:error, :plan_not_found} = PlanAdapter.replan_on_failure(
        "nonexistent-id",
        failed_task_id,
        "test failure",
        %{}
      )
  """
  def replan_on_failure(plan_id, failed_task_id, failure_reason, context \\ %{})
      when is_binary(plan_id) and is_binary(failed_task_id) and is_binary(failure_reason) and
             is_map(context) do
    Logger.info(
      "[PlanAdapter] Attempting replan: plan_id=#{plan_id}, failed_task_id=#{failed_task_id}, reason=#{failure_reason}"
    )

    with {:ok, plan} <- fetch_plan(plan_id, context),
         :ok <- validate_plan_status(plan),
         {:ok, failed_task} <- fetch_task(failed_task_id, context),
         {:ok, remaining_tasks} <- fetch_remaining_tasks(plan_id, context),
         {:ok, new_subtasks} <-
           call_llm_for_replan(plan, failed_task, remaining_tasks, failure_reason),
         {:ok, new_tasks} <- create_new_tasks(plan_id, new_subtasks, context),
         :ok <- emit_adaptation_event(plan_id, failed_task_id, new_tasks, context) do
      Logger.info(
        "[PlanAdapter] Successfully replanned: plan_id=#{plan_id}, new_task_count=#{length(new_tasks)}"
      )

      {:ok, new_tasks}
    else
      {:error, reason} ->
        Logger.warning(
          "[PlanAdapter] Replan failed: plan_id=#{plan_id}, reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Private helpers

  defp fetch_plan(plan_id, context) do
    plan_store = Application.get_env(:bot_army_gtd, :plan_store, BotArmyGtd.PlanStore)
    tenant_id = context[:tenant_id] || "default"

    case plan_store.get(tenant_id, plan_id) do
      {:ok, plan} -> {:ok, plan}
      {:error, _} -> {:error, :plan_not_found}
    end
  rescue
    _e -> {:error, :plan_not_found}
  end

  defp fetch_task(task_id, context) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = context[:tenant_id] || "default"

    if function_exported?(task_store, :get, 2) do
      case task_store.get(tenant_id, task_id) do
        {:ok, task} -> {:ok, task}
        {:error, _} -> {:error, :task_not_found}
      end
    else
      case task_store.get(task_id) do
        {:ok, task} -> {:ok, task}
        {:error, _} -> {:error, :task_not_found}
      end
    end
  rescue
    _e -> {:error, :task_not_found}
  end

  defp fetch_remaining_tasks(plan_id, context) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = context[:tenant_id] || "default"

    case task_store.list_by_plan(tenant_id, plan_id) do
      {:ok, tasks} ->
        # Filter to only incomplete tasks
        remaining =
          Enum.reject(tasks, fn t ->
            t["status"] in ["completed", "deleted", "cancelled", "failed"]
          end)

        {:ok, remaining}

      {:error, _} ->
        {:error, :failed_to_fetch_remaining_tasks}
    end
  rescue
    _e -> {:error, :failed_to_fetch_remaining_tasks}
  end

  defp validate_plan_status(plan) do
    status = plan["status"]

    if status in ["executing", "adapting"] do
      :ok
    else
      {:error, :invalid_plan_status}
    end
  end

  defp call_llm_for_replan(plan, failed_task, remaining_tasks, failure_reason) do
    goal = plan["goal"]
    context = plan["context"] || %{}

    # Build the replan prompt
    prompt = build_replan_prompt(goal, failed_task, remaining_tasks, failure_reason, context)
    system = system_prompt()

    payload = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "system" => system
    }

    Logger.debug(
      "[PlanAdapter] Calling LLM to replan",
      subject: "bot_army_llm.converse",
      timeout_ms: @default_timeout_ms
    )

    case BotArmyLibraryRuntime.NATS.Publisher.request(
           "bot_army_llm.converse",
           payload,
           timeout_ms: @default_timeout_ms
         ) do
      {:ok, response} ->
        case Decomposer.parse_subtasks(response) do
          {:ok, subtasks} ->
            Logger.info("[PlanAdapter] LLM generated #{length(subtasks)} new subtasks")
            {:ok, subtasks}

          {:error, reason} ->
            Logger.error("[PlanAdapter] Failed to parse LLM response", reason: reason)
            {:error, :parse_error}
        end

      {:error, :timeout} ->
        Logger.warning("[PlanAdapter] LLM request timed out")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("[PlanAdapter] LLM request failed", reason: reason)
        {:error, reason}
    end
  end

  defp build_replan_prompt(goal, failed_task, remaining_tasks, failure_reason, context) do
    failed_desc = failed_task["description"] || failed_task["title"] || "unknown task"

    remaining_list =
      if Enum.empty?(remaining_tasks) do
        "No remaining tasks"
      else
        Enum.map_join(remaining_tasks, "\n", fn t -> "- #{t["description"] || t["title"]}" end)
      end

    context_json =
      if map_size(context) > 0 do
        Jason.encode!(context)
      else
        "{}"
      end

    """
    Original Goal: #{goal}

    Context: #{context_json}

    Plan Failure:
    - Failed task: #{failed_desc}
    - Reason: #{failure_reason}

    Remaining planned tasks:
    #{remaining_list}

    Your task: Re-generate the plan for the remaining steps, taking into account the failure.
    You may:
    1. Skip the failed task (it's already been attempted)
    2. Try the failed step with a different approach
    3. Add prerequisite steps to handle the failure
    4. Suggest alternative approaches to achieve the goal

    Each subtask should be concrete, executable, and completable in 5-10 minutes.

    Available bots: gtd, llm, dispatcher, synapse, job_applications, learning, terrain, rpg, advocacy, chore, fitness, inbox, notifications, claude_bridge.

    Return JSON array (and ONLY JSON, no markdown, no code blocks):
    [
      {
        "order": 1,
        "description": "Detailed description of what needs to happen",
        "target_bot": "bot_army_gtd",
        "target_subject": "gtd.task.create",
        "payload": {
          "title": "...",
          "description": "...",
          "due_date": "ISO8601 or null"
        },
        "depends_on": [],
        "needs_verification": true
      }
    ]
    """
  end

  defp system_prompt do
    """
    You are a task replanning expert. When a plan fails, you must regenerate the remaining steps
    to recover from the failure and achieve the original goal.

    Be pragmatic and adaptive: consider alternative approaches, add error handling steps if needed,
    and ensure each new step can be executed independently.

    Always respond with valid JSON only—no markdown, no explanation, no code blocks.
    """
  end

  defp create_new_tasks(plan_id, new_subtasks, context) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = context[:tenant_id] || "default"
    user_id = context[:user_id] || "default"

    tasks =
      Enum.map(new_subtasks, fn subtask ->
        task_data = %{
          "title" => subtask["description"],
          "description" => "Auto-replanned task after failure",
          "status" => "active",
          "priority" => "normal",
          "source" => "plan_replan",
          "generated_by_ai" => true,
          "plan_id" => plan_id,
          "plan_order" => subtask["order"],
          "tenant_id" => tenant_id,
          "user_id" => user_id,
          "metadata" => %{
            "replanned" => true,
            "replanned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }

        case task_store.create(task_data) do
          {:ok, task} ->
            Logger.debug("[PlanAdapter] Created replanned task: #{task["id"]}")
            task

          {:error, reason} ->
            Logger.warning("[PlanAdapter] Failed to create replanned task: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(tasks) do
      {:error, :failed_to_create_tasks}
    else
      {:ok, tasks}
    end
  rescue
    e ->
      Logger.error("[PlanAdapter] Task creation failed: #{inspect(e)}")
      {:error, :database_error}
  end

  defp emit_adaptation_event(plan_id, failed_task_id, new_tasks, context) do
    tenant_id = context[:tenant_id]
    user_id = context[:user_id]

    event_data =
      BotArmyGtd.EventBuilder.build_event(
        "events.gtd.plan.adapted",
        %{
          "plan_id" => plan_id,
          "failed_task_id" => failed_task_id,
          "new_task_count" => length(new_tasks),
          "new_tasks" => new_tasks,
          "adapted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("[PlanAdapter] Published plan.adapted event")
        :ok

      :ok ->
        Logger.debug("[PlanAdapter] Published plan.adapted event")
        :ok

      {:error, reason} ->
        Logger.error("[PlanAdapter] Failed to publish adaptation event: #{inspect(reason)}")
        {:error, :publish_failed}
    end
  rescue
    e ->
      Logger.error("[PlanAdapter] Event publication failed: #{inspect(e)}")
      {:error, :publish_failed}
  end
end

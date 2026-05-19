defmodule BotArmyGtd.Handlers.SubtaskHandler do
  @moduledoc """
  Handles distributed subtask execution from Dispatcher Orchestrator.

  Receives subtask intents from the dispatcher and creates GTD tasks.
  Part of Phase 2: Autonomous Task Decomposition infrastructure.

  Expected payload:
  ```
  {
    "subtask_id": "uuid",
    "decomposition_id": "uuid",
    "description": "What to do",
    "task_payload": {
      "title": "Task title",
      "description": "Task description",
      ...
    }
  }
  ```

  Publishes `dispatcher.subtask.completed` with created task ID.
  """

  require Logger
  alias BotArmyCore.Tenant
  alias BotArmyGtd.{EventBuilder, TaskStore}
  alias BotArmyRuntime.NATS.Publisher

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle a dispatcher subtask intent for GTD task creation.
  """
  def handle_subtask_intent(message) do
    payload = message["payload"]
    subtask_id = payload["subtask_id"]
    decomposition_id = payload["decomposition_id"]
    task_payload = payload["task_payload"] || %{}
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    Logger.info("[SubtaskHandler] Creating GTD task from subtask",
      subtask_id: subtask_id,
      decomposition_id: decomposition_id
    )

    case create_task(task_payload, tenant_id, user_id) do
      {:ok, task} ->
        publish_completion(subtask_id, decomposition_id, "completed", %{
          "task_id" => task["id"],
          "title" => task["title"]
        })

      {:error, reason} ->
        Logger.warning("[SubtaskHandler] Task creation failed",
          subtask_id: subtask_id,
          reason: inspect(reason)
        )

        publish_completion(subtask_id, decomposition_id, "failed", %{
          "error" => inspect(reason)
        })
    end
  end

  # Private: Create the GTD task
  defp create_task(task_payload, tenant_id, user_id) do
    title = Map.get(task_payload, "title", "Subtask")
    description = Map.get(task_payload, "description", "")

    task_data = %{
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "title" => title,
      "description" => description,
      "status" => "inbox",
      "priority" => Map.get(task_payload, "priority", "medium")
    }

    task_store().create(task_data)
  end

  # Private: Publish completion back to dispatcher
  defp publish_completion(subtask_id, decomposition_id, status, result) do
    event_data =
      EventBuilder.build_event("dispatcher.subtask.completed", %{
        "subtask_id" => subtask_id,
        "decomposition_id" => decomposition_id,
        "status" => status,
        "result" => result
      })

    case Publisher.publish("dispatcher.subtask.completed", event_data) do
      {:ok, _subject} ->
        Logger.debug("[SubtaskHandler] Published task completion",
          subtask_id: subtask_id,
          status: status
        )

      {:error, reason} ->
        Logger.error("[SubtaskHandler] Failed to publish completion: #{inspect(reason)}")
    end
  end
end

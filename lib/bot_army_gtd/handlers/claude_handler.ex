defmodule BotArmyGtd.Handlers.ClaudeHandler do
  @moduledoc """
  Handles Claude-specific task automation.

  This handler processes events from Claude Code to enable automated task
  generation and completion based on successful operations.

  ## Features

  - Auto task generation from Claude task requests
  - Auto task completion on successful operations
  - Context-aware task association with parent tasks

  ## Events

  - `claude.task.create` - Create a task from Claude's request
  - `claude.operation.success` - Auto-complete a task on successful operation
  """

  require Logger
  alias BotArmyCore.Tenant
  alias BotArmyGtd.{EventBuilder, NATS.Publisher, TaskStore}

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle Claude task creation request.

  Creates a task from Claude's request with auto-generated metadata.
  Publishes gtd.task.created on success.

  Returns `:ok` if successful.
  """
  def handle_task_create(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_create_payload(payload) do
      :ok ->
        process_create(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid Claude task create payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task request", tenant_id, user_id)
    end
  end

  @doc """
  Handle Claude operation success event.

  Auto-completes the associated task when Claude reports a successful operation.
  The task_id is extracted from the payload and the task is marked as completed.

  Returns `:ok` if successful.
  """
  def handle_operation_success(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_operation_success_payload(payload) do
      :ok ->
        process_operation_success(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid Claude operation success payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid operation success event", tenant_id, user_id)
    end
  end

  # Private validation

  defp validate_create_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "title") do
      :ok
    end
  end

  defp validate_create_payload(_), do: {:error, :invalid_payload}

  defp validate_operation_success_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
    |> then(fn
      :ok -> require_field(payload, "operation")
      err -> err
    end)
  end

  defp validate_operation_success_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  # Private processing

  defp process_create(payload, event_id, tenant_id, user_id) do
    title = payload["title"]
    description = payload["description"]
    project_id = payload["project_id"]
    parent_task_id = payload["parent_task_id"]
    labels = payload["labels"] || []

    case find_existing_auto_task(tenant_id, title, description) do
      {:ok, existing_task} ->
        source_metadata =
          existing_task
          |> Map.get("source_metadata", %{})
          |> Map.put("triggered_by_event_id", event_id)
          |> Map.put("auto_generated", true)

        update_payload = %{
          "source_metadata" => source_metadata,
          "labels" => labels
        }

        case task_store().update(existing_task["id"], update_payload) do
          {:ok, updated_task} ->
            Logger.info(
              "Claude task reused: task_id=#{updated_task["id"]}, event_id=#{event_id}, auto_generated=true"
            )

            publish_event("gtd.task.updated", updated_task, event_id, tenant_id, user_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to update existing Claude task: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to update existing task", tenant_id, user_id)
            {:error, reason}
        end

      :not_found ->
        # Create task with Claude context
        case task_store().create(%{
               "tenant_id" => tenant_id,
               "user_id" => user_id,
               "title" => title,
               "description" => description,
               "project_id" => project_id,
               "status" => "active",
               "priority" => "normal",
               "labels" => labels,
               "source" => "claude",
               "source_metadata" => %{
                 "triggered_by_event_id" => event_id,
                 "auto_generated" => true
               },
               "parent_task_id" => parent_task_id
             }) do
          {:ok, task} ->
            Logger.info(
              "Claude task created: task_id=#{task["id"]}, event_id=#{event_id}, auto_generated=true"
            )

            publish_event("gtd.task.created", task, event_id, tenant_id, user_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to create Claude task: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to create task", tenant_id, user_id)
            {:error, reason}
        end
    end
  end

  defp find_existing_auto_task(tenant_id, title, description) do
    filters = %{"status" => ["active", "inbox", "pending", "claimed"]}

    case task_store().list(tenant_id, filters) do
      {:ok, tasks} ->
        case Enum.find(tasks, &matches_claude_task?(&1, title, description)) do
          nil -> :not_found
          match -> {:ok, match}
        end

      {:error, _reason} ->
        :not_found
    end
  end

  defp matches_claude_task?(task, title, description) do
    task["source"] == "claude" and
      task["title"] == title and
      (task["description"] || "") == (description || "") and
      (task["source_metadata"] || %{})["auto_generated"] == true
  end

  defp process_operation_success(payload, event_id, tenant_id, user_id) do
    task_id = payload["task_id"]
    operation = payload["operation"]
    result = payload["result"] || %{}

    case task_store().update(task_id, %{
           "status" => "completed",
           "result" => %{
             "operation" => operation,
             "success" => true,
             "output" => result
           }
         }) do
      {:ok, task} ->
        Logger.info(
          "Claude operation completed: task_id=#{task_id}, operation=#{operation}, event_id=#{event_id}"
        )

        # Publish completion event
        event_data =
          EventBuilder.build_event(
            "gtd.task.completed",
            %{
              "task" => task,
              "triggered_by_event_id" => event_id,
              "auto_completed" => true
            },
            tenant_id: tenant_id,
            user_id: user_id,
            triggered_by: "claude"
          )

        case Publisher.publish(event_data) do
          {:ok, _subject} ->
            Logger.debug("Published task.completed event for Claude auto-completion")

          {:error, reason} ->
            Logger.error("Failed to publish completion event: #{inspect(reason)}")
        end

        :ok

      {:error, reason} ->
        Logger.error("Failed to complete Claude task #{task_id}: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to complete task", tenant_id, user_id)
        {:error, reason}
    end
  end

  # Private publishing

  defp publish_event(event_type, task, event_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        event_type,
        %{
          "task" => task,
          "triggered_by_event_id" => event_id,
          "auto_generated" => true
        },
        tenant_id: tenant_id,
        user_id: user_id,
        triggered_by: "claude"
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published task event from Claude handler")
      {:error, reason} -> Logger.error("Failed to publish task event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id,
        triggered_by: "claude"
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published error event from Claude handler")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end

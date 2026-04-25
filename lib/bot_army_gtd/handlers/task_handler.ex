defmodule BotArmyGtd.Handlers.TaskHandler do
  @moduledoc """
  Handles task-related events for the GTD bot.

  This module processes incoming task messages:
  - `gtd.task.create` - Create a new task
  - `gtd.task.update` - Update existing task
  - `gtd.task.complete` - Mark task as complete

  Each operation validates the input, performs the action, and publishes
  corresponding response events.

  ## Dependencies

  - `BotArmyGtd.TaskStore` - Persistent task storage
  - `BotArmyGtd.NATS.Publisher` - Event publishing
  """

  require Logger

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle task creation event.

  Validates the task data, stores it, and publishes a task.created event.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_create(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    # Stamp tenant and user context into payload
    stamped_payload =
      Map.merge(payload, %{
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case validate_create_payload(stamped_payload) do
      :ok ->
        case task_store().create(stamped_payload) do
          {:ok, task} ->
            Logger.info("Task created: task_id=#{task["id"]}, event_id=#{event_id}")

            publish_event(
              "gtd.task.created",
              stamped_payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            {:ok, task}

          {:error, reason} ->
            Logger.error("Failed to create task: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to create task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task creation payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task update event.

  Validates the update data, applies it, and publishes a task.updated event.
  """
  def handle_update(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    case validate_update_payload(payload) do
      :ok ->
        task_id = payload["task_id"]

        case task_store().update(task_id, payload) do
          {:ok, task} ->
            Logger.info("Task updated: task_id=#{task_id}, event_id=#{event_id}")

            publish_event(
              "gtd.task.updated",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to update task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to update task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task update payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task completion event.

  Marks the task as complete and publishes a task.completed event.
  """
  def handle_complete(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    case validate_complete_payload(payload) do
      :ok ->
        task_id = payload["task_id"]

        case task_store().complete(task_id) do
          {:ok, task} ->
            Logger.info("Task completed: task_id=#{task_id}, event_id=#{event_id}")

            publish_event(
              "gtd.task.completed",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to complete task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to complete task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task completion payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task defer event.

  Defers a task to a future date and publishes a task.state.updated event.
  """
  def handle_defer(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    case validate_defer_payload(payload) do
      :ok ->
        task_id = payload["task_id"]
        defer_until = payload["defer_until"]

        case task_store().update(task_id, %{"due_date" => defer_until}) do
          {:ok, task} ->
            Logger.info(
              "Task deferred: task_id=#{task_id}, until=#{defer_until}, event_id=#{event_id}"
            )

            publish_event(
              "gtd.task.state.updated",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to defer task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to defer task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task defer payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid defer data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task delete event.

  Marks a task as deleted and publishes a task.state.updated event.
  """
  def handle_delete(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    case validate_delete_payload(payload) do
      :ok ->
        task_id = payload["task_id"]

        case task_store().update(task_id, %{"status" => "deleted"}) do
          {:ok, task} ->
            Logger.info("Task deleted: task_id=#{task_id}, event_id=#{event_id}")

            publish_event(
              "gtd.task.state.updated",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to delete task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to delete task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task delete payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid delete data", tenant_id, user_id)
        {:error, reason}
    end
  end

  # Private functions

  defp validate_create_payload(payload) when is_map(payload) do
    require_field(payload, "title")
  end

  defp validate_create_payload(_), do: {:error, :invalid_payload}

  defp validate_update_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_update_payload(_), do: {:error, :invalid_payload}

  defp validate_complete_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_complete_payload(_), do: {:error, :invalid_payload}

  defp validate_defer_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "task_id"),
         :ok <- require_field(payload, "defer_until") do
      :ok
    end
  end

  defp validate_defer_payload(_), do: {:error, :invalid_payload}

  defp validate_delete_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_delete_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp publish_event(event_type, _payload, task, event_id, _original_message, tenant_id, user_id) do
    event_data = %{
      "event" => event_type,
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "task" => task,
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published event: #{event_type}")
      {:error, reason} -> Logger.error("Failed to publish event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    error_event = %{
      "event" => "gtd.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(error_event) do
      {:ok, _subject} -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end

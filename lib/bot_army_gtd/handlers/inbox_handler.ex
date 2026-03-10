defmodule BotArmyGtd.Handlers.InboxHandler do
  @moduledoc """
  Handles inbox-related events for the GTD bot.

  This module processes incoming inbox messages:
  - `gtd.inbox.add` - Add an item to the inbox

  The handler validates the input, stores the inbox item, creates a task,
  and publishes events.

  ## Dependencies

  - `BotArmyGtd.InboxItemStore` - Inbox item storage
  - `BotArmyGtd.TaskStore` - Task storage
  - `BotArmyGtd.NATS.Publisher` - Event publishing
  """

  require Logger

  defp inbox_item_store do
    Application.get_env(:bot_army_gtd, :inbox_item_store, BotArmyGtd.InboxItemStore)
  end

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle inbox add event.

  Validates the inbox item, creates both an inbox item and a task,
  and publishes corresponding events.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_add(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_add_payload(payload) do
      :ok ->
        process_inbox_add(payload, event_id, message)

      {:error, reason} ->
        Logger.warning("Invalid inbox add payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid inbox data")
    end
  end

  # Private functions

  defp validate_add_payload(payload) when is_map(payload) do
    require_field(payload, "raw_text")
  end

  defp validate_add_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_inbox_add(payload, event_id, _original_message) do
    raw_text = payload["raw_text"]
    source = Map.get(payload, "source", "user")
    source_metadata = Map.get(payload, "source_metadata", %{})

    # Create inbox item
    case inbox_item_store().create(%{
      "raw_text" => raw_text,
      "source" => source,
      "source_metadata" => source_metadata
    }) do
      {:ok, inbox_item} ->
        Logger.info("Inbox item created: item_id=#{inbox_item["id"]}, event_id=#{event_id}")

        # Create corresponding task
        case task_store().create(%{
          "title" => raw_text,
          "project_id" => "_inbox",
          "description" => nil,
          "status" => "inbox",
          "priority" => "normal",
          "source" => source,
          "source_metadata" => source_metadata
        }) do
          {:ok, task} ->
            Logger.info("Task created from inbox: task_id=#{task["id"]}")

            # Mark inbox item as processed
            inbox_item_store().mark_processed(inbox_item["id"])

            # Publish inbox.item.added event
            publish_inbox_item_added(inbox_item, event_id)

            # Publish task.created event
            publish_task_created(task, event_id)

          {:error, reason} ->
            Logger.error("Failed to create task from inbox: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to create task from inbox")
        end

      {:error, reason} ->
        Logger.error("Failed to create inbox item: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to add item to inbox")
    end
  end

  defp publish_inbox_item_added(item, event_id) do
    event_data = %{
      "event" => "gtd.inbox.item.added",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "inbox_item" => item,
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published inbox.item.added event")
      {:error, reason} -> Logger.error("Failed to publish inbox event: #{inspect(reason)}")
    end
  end

  defp publish_task_created(task, event_id) do
    event_data = %{
      "event" => "gtd.task.created",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "task" => task,
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published task.created event")
      {:error, reason} -> Logger.error("Failed to publish task event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message) do
    error_event = %{
      "event" => "gtd.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(error_event) do
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end

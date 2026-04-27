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

  @doc """
  Handle inbox add event.

  Validates the inbox item, creates both an inbox item and a task,
  and publishes corresponding events.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_add(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    case validate_add_payload(payload) do
      :ok ->
        process_inbox_add(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid inbox add payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid inbox data", tenant_id, user_id)
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

  defp process_inbox_add(payload, event_id, _original_message, tenant_id, user_id) do
    raw_text = payload["raw_text"]
    source = Map.get(payload, "source", "user")
    source_metadata = Map.get(payload, "source_metadata", %{})

    # Create inbox item
    case inbox_item_store().create(%{
           "tenant_id" => tenant_id,
           "user_id" => user_id,
           "raw_text" => raw_text,
           "source" => source,
           "source_metadata" => source_metadata
         }) do
      {:ok, inbox_item} ->
        Logger.info("Inbox item created: item_id=#{inbox_item["id"]}, event_id=#{event_id}")

        # Publish inbox.item.added event
        publish_inbox_item_added(inbox_item, event_id, tenant_id, user_id)

        # Request parsing from LLM bot
        publish_parse_request(
          raw_text,
          inbox_item["id"],
          source,
          source_metadata,
          event_id,
          tenant_id,
          user_id
        )

      {:error, reason} ->
        Logger.error("Failed to create inbox item: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to add item to inbox", tenant_id, user_id)
    end
  end

  defp publish_inbox_item_added(item, event_id, tenant_id, user_id) do
    event_data =
      BotArmyGtd.EventBuilder.build_event(
        "gtd.inbox.item.added",
        %{
          "inbox_item" => item,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published inbox.item.added event")
      {:error, reason} -> Logger.error("Failed to publish inbox event: #{inspect(reason)}")
    end
  end

  defp publish_parse_request(
         raw_text,
         inbox_item_id,
         source,
         source_metadata,
         event_id,
         tenant_id,
         user_id
       ) do
    # Request LLM bot to parse the raw text into structured task data
    output_schema = %{
      "type" => "object",
      "required" => ["title"],
      "properties" => %{
        "title" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "project" => %{"type" => "string"},
        "priority" => %{"enum" => ["low", "normal", "high"]},
        "due_date" => %{"type" => "string"},
        "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }

    event_data =
      BotArmyGtd.EventBuilder.build_event(
        "llm.response.parse",
        %{
          "text" => raw_text,
          "output_schema" => output_schema,
          "inbox_item_id" => inbox_item_id,
          "source" => source,
          "source_metadata" => source_metadata,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyRuntime.NATS.Publisher.publish("llm.response.parse", event_data) do
      {:ok, _subject} -> Logger.debug("Published parse request to LLM bot")
      {:error, reason} -> Logger.error("Failed to publish parse request: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      BotArmyGtd.EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end

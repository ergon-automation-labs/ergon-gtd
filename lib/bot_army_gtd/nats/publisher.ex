defmodule BotArmyGtd.NATS.Publisher do
  @moduledoc """
  NATS event publisher for the GTD bot.

  Publishes response events from GTD handlers back to the NATS broker.
  Events include task.created, task.updated, task.completed, and error events.

  ## Features

  - Serialization of events to JSON
  - Subject routing based on event type
  - Error handling and logging
  - Connection management

  ## Implementation

  In production, this would publish to a real NATS broker. The structure
  supports dependency injection for testing and mocking.
  """

  require Logger

  @nats_url System.get_env("NATS_URL", "nats://localhost:4222")

  @doc """
  Publish an event to NATS.

  The event map should contain:
  - `"event"` - Event type (e.g., "gtd.task.created")
  - `"event_id"` - Unique event identifier
  - `"timestamp"` - ISO8601 timestamp
  - `"source"` - Source bot (e.g., "bot_army_gtd")
  - `"source_node"` - Node name
  - `"triggered_by"` - Audit value
  - `"schema_version"` - Schema version
  - `"payload"` - Event payload

  Returns `:ok` if successful, or `{:error, reason}` on failure.
  """
  def publish(event) when is_map(event) do
    try do
      subject = derive_subject(event["event"])
      body = Jason.encode!(event)

      case do_publish(subject, body) do
        :ok ->
          Logger.debug("Published event to #{subject}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to publish to #{subject}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Exception during publish: #{inspect(e)}")
        {:error, e}
    end
  end

  def publish(_) do
    {:error, :invalid_event}
  end

  # Private functions

  defp do_publish(subject, body) do
    # In production, this would connect to NATS and publish
    # For now, log the publish attempt
    Logger.info("Publishing to #{subject}: #{String.slice(body, 0, 100)}...")
    :ok
  end

  defp derive_subject(event_type) when is_binary(event_type) do
    # Map internal event types to NATS subject
    case event_type do
      "gtd.task.created" -> "events.gtd.task.created"
      "gtd.task.updated" -> "events.gtd.task.updated"
      "gtd.task.completed" -> "events.gtd.task.completed"
      "gtd.project.created" -> "events.gtd.project.created"
      "gtd.project.updated" -> "events.gtd.project.updated"
      "gtd.error" -> "events.gtd.error"
      _ -> "events.gtd.unknown"
    end
  end

  defp derive_subject(_) do
    "events.gtd.unknown"
  end
end

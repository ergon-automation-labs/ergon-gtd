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
  alias BotArmyGtd.TaskIntakeGuard
  alias BotArmyLibraryRuntime.NATS.Publisher

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
    if TaskIntakeGuard.suspicious_outbound_created_event?(event) do
      Logger.warning(
        "Dropped suspicious outbound gtd.task.created event: event_id=#{event["event_id"]} source_node=#{event["source_node"]} payload=#{inspect(event["payload"])}"
      )

      {:error, :dropped_suspected_test_data}
    else
      try do
        subject = derive_subject(event["event"])
        body = Jason.encode!(event)

        case do_publish(subject, body) do
          {:ok, _subject} ->
            Logger.debug("Published event to #{subject}")
            {:ok, subject}

          :ok ->
            Logger.debug("Published event to #{subject}")
            {:ok, subject}

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
  end

  def publish(_) do
    {:error, :invalid_event}
  end

  # Private functions

  defp do_publish(subject, body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        Publisher.publish(subject, payload)

      {:error, reason} ->
        Logger.error("Failed to decode body for #{subject}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @event_subject_map %{
    "gtd.inbox.item.added" => "events.gtd.inbox.item.added",
    "gtd.task.created" => "events.gtd.task.created",
    "gtd.task.updated" => "events.gtd.task.updated",
    "gtd.task.completed" => "events.gtd.task.completed",
    "gtd.task.state.updated" => "events.gtd.task.state.updated",
    "gtd.decomposition.completed" => "events.gtd.decomposition.completed",
    "gtd.decomposition.due_for_review" => "events.gtd.decomposition.due_for_review",
    "gtd.decomposition.reviewed" => "events.gtd.decomposition.reviewed",
    "gtd.decomposition.approved" => "events.gtd.decomposition.approved",
    "gtd.project.created" => "events.gtd.project.created",
    "gtd.project.updated" => "events.gtd.project.updated",
    "gtd.log.entry.created" => "events.gtd.log.entry.created",
    "gtd.log.entry.enriched" => "events.gtd.log.entry.enriched",
    "gtd.log.daily.new" => "gtd.log.daily.new",
    "gtd.error" => "events.gtd.error"
  }

  defp derive_subject(event_type) when is_binary(event_type) do
    Map.get(@event_subject_map, event_type, "events.gtd.unknown")
  end

  defp derive_subject(_) do
    "events.gtd.unknown"
  end
end

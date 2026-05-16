defmodule BotArmyGtd.Handlers.LogEntryHandler do
  @moduledoc """
  Handles log entry creation events for the GTD bot.

  This module processes incoming log entry messages:
  - `gtd.log.create` - Create a new log entry

  Each operation validates the input, stores it in the database, writes to the
  daily markdown file, and publishes corresponding response events.
  """

  require Logger
  alias BotArmyGtd.{EventBuilder, Handlers.LogEnrichmentHandler, LogEntryStore, NATS.Publisher}

  defp log_entry_store do
    Application.get_env(:bot_army_gtd, :log_entry_store, BotArmyGtd.LogEntryStore)
  end

  defp daily_log_dir do
    Application.get_env(
      :bot_army_gtd,
      :daily_log_dir,
      "#{System.user_home!()}/Documents/daily_logs"
    )
  end

  @doc """
  Handle log entry creation event.

  Validates the entry data, stores it, writes to the daily markdown file,
  and publishes a log.entry.created event.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_create(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_create_payload(payload) do
      :ok ->
        case log_entry_store().create(payload) do
          {:ok, entry} ->
            Logger.info("Log entry created: entry_id=#{entry["id"]}, event_id=#{event_id}")
            write_to_file(entry)
            publish_events(entry, event_id, message)
            LogEnrichmentHandler.request_enrichment(entry)
            :ok

          {:error, reason} ->
            Logger.error("Failed to create log entry: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to create log entry")
            :ok
        end

      {:error, reason} ->
        Logger.warning("Invalid log entry payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid log entry data")
        :ok
    end
  end

  # Private functions

  defp validate_create_payload(payload) when is_map(payload) do
    cond do
      not Map.has_key?(payload, "body") or payload["body"] == nil ->
        {:error, "body is required"}

      not is_binary(payload["body"]) ->
        {:error, "body must be a string"}

      true ->
        :ok
    end
  end

  defp validate_create_payload(_) do
    {:error, "payload must be a map"}
  end

  defp write_to_file(entry) do
    dt =
      entry["occurred_at"]
      |> NaiveDateTime.from_iso8601!()

    date = dt |> NaiveDateTime.to_date()
    time = dt |> NaiveDateTime.to_time()

    # Format time as HH:MM
    hour = String.pad_leading(to_string(time.hour), 2, "0")
    minute = String.pad_leading(to_string(time.minute), 2, "0")
    time_str = "#{hour}:#{minute}"

    dir = daily_log_dir()
    File.mkdir_p!(dir)

    filename = "#{dir}/#{date}.md"
    line = "#{time_str} - #{entry["body"]}\n"

    File.write(filename, line, [:append])

    # Mark as written in the store
    log_entry_store().mark_file_written(entry["id"])
  rescue
    e ->
      Logger.warning("Failed to write log entry to file: #{inspect(e)}")
      # Continue anyway - Postgres is source of truth
  end

  defp publish_events(entry, event_id, original_message) do
    # Publish events.gtd.log.entry.created
    event_created = build_event("gtd.log.entry.created", entry, event_id, original_message)
    Publisher.publish(event_created)

    # Publish gtd.log.daily.new (bare, for downstream consumers)
    daily_event = build_event("gtd.log.daily.new", entry, event_id, original_message)
    Publisher.publish(daily_event)

    :ok
  end

  defp build_event(event_type, entry, event_id, original_message) do
    %{
      "event" => event_type,
      "event_id" => event_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => original_message["source"] || "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => original_message["triggered_by"] || "gtd.log.create",
      "schema_version" => "1.0",
      "payload" => entry
    }
  end

  defp publish_error(event_id, reason, message) do
    error_event = %{
      "event" => "gtd.error",
      "event_id" => event_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "gtd.log.create",
      "schema_version" => "1.0",
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason)
      }
    }

    Publisher.publish(error_event)
  end
end

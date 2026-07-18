defmodule BotArmyGtd.Handlers.LogEnrichmentHandler do
  @moduledoc """
  Handles log entry enrichment via LLM analysis.

  This handler requests LLM enrichment of log entries by:
  1. Publishing to llm.response.parse with the log entry body
  2. Receiving the LLM's structured analysis
  3. Storing the enrichment data and publishing events.gtd.log.entry.enriched

  Enrichment is fire-and-forget — it never blocks or fails entry creation.
  """

  require Logger

  @doc """
  Request LLM enrichment of a log entry.

  Publishes to llm.response.parse (single-shot, not chain).
  Fire-and-forget — always returns :ok, never raises.

  The LLM response will be routed back via handle_enriched/1.
  """
  def request_enrichment(entry) when is_map(entry) do
    log_entry_id = entry["id"]
    body = entry["body"]

    case {log_entry_id, body} do
      {nil, _} ->
        :ok

      {_, nil} ->
        :ok

      {entry_id, entry_body} when is_binary(entry_id) and is_binary(entry_body) ->
        event_data = build_llm_request(entry_id, entry_body)
        BotArmyLibraryRuntime.NATS.Publisher.publish("llm.response.parse", event_data)
        :ok

      _ ->
        :ok
    end
  rescue
    _e ->
      :ok
  end

  def request_enrichment(_), do: :ok

  @doc """
  Handle LLM enrichment response.

  Extracts log_entry_id and structured_data from the message payload,
  marks the entry as enriched, and publishes the enriched event.

  Always returns :ok (non-fatal).
  """
  def handle_enriched(message) when is_map(message) do
    payload = message["payload"]

    case {
      get_in(payload, ["log_entry_id"]),
      get_in(payload, ["structured_data"])
    } do
      {nil, _} ->
        Logger.warning("Missing log_entry_id in enrichment response")
        :ok

      {_id, nil} ->
        Logger.warning("Missing structured_data in enrichment response")
        :ok

      {_id, data} when not is_map(data) ->
        Logger.warning("structured_data is not a map in enrichment response")
        :ok

      {log_entry_id, structured_data}
      when is_binary(log_entry_id) and is_map(structured_data) ->
        case log_entry_store().mark_enriched(log_entry_id, structured_data) do
          {:ok, updated_entry} ->
            publish_enriched_event(updated_entry)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to mark log entry as enriched: #{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _e ->
      :ok
  end

  def handle_enriched(_), do: :ok

  # Private functions

  defp build_llm_request(log_entry_id, body) do
    %{
      "event" => "llm.response.parse",
      "event_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "gtd.log.create",
      "schema_version" => "1.0",
      "payload" => %{
        "model" => "gpt-4-turbo",
        "text" => build_prompt(body),
        "output_schema" => output_schema(),
        "max_retries" => 2,
        "log_entry_id" => log_entry_id,
        "enrichment_source" => "log_enrichment"
      }
    }
  end

  defp build_prompt(body) do
    """
    Analyze this activity log entry and extract structured metadata. Return ONLY a JSON object with these optional fields:
    - duration_minutes: integer (only if time is clearly mentioned, e.g. "2 hours" = 120, "30 min" = 30)
    - energy_level: "low", "medium", or "high" (infer from language, e.g. "exhausted" = low, "energized" = high)
    - sentiment: "positive", "neutral", or "negative"
    - category: one of work/personal/health/learning/care/admin/social (only if you're confident, else omit)
    - tags: array of up to 5 short relevant string tags
    - task_link_suggestion: null

    Log entry: "#{body}"
    """
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "duration_minutes" => %{"type" => "integer", "minimum" => 0},
        "energy_level" => %{"type" => "string", "enum" => ["low", "medium", "high"]},
        "sentiment" => %{"type" => "string", "enum" => ["positive", "neutral", "negative"]},
        "category" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "task_link_suggestion" => %{"type" => "string"}
      },
      "additionalProperties" => false
    }
  end

  defp publish_enriched_event(entry) do
    event = %{
      "event" => "gtd.log.entry.enriched",
      "event_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "log_enrichment",
      "schema_version" => "1.0",
      "payload" => entry
    }

    BotArmyGtd.NATS.Publisher.publish(event)
  end

  defp log_entry_store do
    Application.get_env(:bot_army_gtd, :log_entry_store, BotArmyGtd.LogEntryStore)
  end
end

defmodule BotArmyGtd.NATS.DecodeError do
  @moduledoc """
  Answers a decode failure with the message that would have worked.

  A bare `"Invalid message format"` costs the caller a whole round of guessing
  while the decoder already knows *which* fields are missing and the subject
  already knows what its payload looks like. Both belong in the reply.

  Measured 2026-11-25: `gtd.task.complete` was sent

      {"event_id": "evt-1", "payload": {"task_id": "…"}}

  and answered

      {"code": "decode_error", "error": "Invalid message format"}

  while the bot's log carried
  `{:missing_required_fields, ["event", "schema_version", "timestamp", …]}`.
  The diagnosis existed — the reply did not carry it, so the next request was a
  guess too.

  The envelope is the same for every `gtd.*` request subject; only `event` and
  `payload` change, and both are supplied by the caller of `reply/3`.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Reply

  @envelope_placeholders [
    {"event_id", "<uuid>"},
    {"schema_version", "<e.g. 1.0>"},
    {"timestamp", "<RFC3339, e.g. 2026-11-25T15:00:00Z>"},
    {"source", "<who is asking, e.g. bot_army_claude_bridge>"},
    {"source_node", "<host, e.g. mini>"},
    {"triggered_by", "<bot, agent or session id>"}
  ]

  @doc """
  Logs the diagnosis and returns the JSON error reply (a binary, like `Reply.error/2`).

  Options:

    * `:payload` — the payload this subject expects, as JSON text
    * `:door` — the `bridge.*` subject that accepts plain JSON instead
  """
  @spec reply(String.t(), term(), keyword()) :: String.t()
  def reply(subject, reason, opts \\ []) do
    message = message(subject, reason, opts)
    Logger.warning(message)
    Reply.error(message, :decode_error)
  end

  @doc """
  The text a caller needs: what was wrong, the envelope to send, and the plain
  JSON door when one exists.
  """
  @spec message(String.t(), term(), keyword()) :: String.t()
  def message(subject, reason, opts \\ []) do
    payload = Keyword.get(opts, :payload, ~s({"…": "…"}))
    door = Keyword.get(opts, :door)

    [headline(subject, reason), envelope(subject, payload), door_hint(door, payload, subject)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp headline(subject, {:missing_required_fields, fields}) do
    "#{subject}: the message is missing required envelope field(s): " <>
      "#{Enum.join(fields, ", ")}. #{subject} answers an envelope, not a flat body."
  end

  defp headline(subject, {:invalid_field_type, field, expected}) do
    "#{subject}: envelope field #{inspect(field)} must be #{expected}."
  end

  defp headline(subject, {:json_decode_error, why}) do
    "#{subject}: the body is not JSON (#{inspect(why)})."
  end

  defp headline(subject, :envelope_not_map) do
    "#{subject}: the body must be a JSON object, not a list or a scalar."
  end

  defp headline(subject, :invalid_message_format) do
    "#{subject}: the body is not a JSON object."
  end

  defp headline(subject, {:unsupported_schema_version, schema, version}) do
    "#{subject}: schema #{inspect(schema)} does not know version #{inspect(version)}."
  end

  defp headline(subject, {:schema_not_found, schema}) do
    "#{subject}: schema #{inspect(schema)} is not installed on this node."
  end

  defp headline(subject, reason) do
    "#{subject}: the message could not be decoded (#{inspect(reason)})."
  end

  defp envelope(subject, payload) do
    fields =
      @envelope_placeholders
      |> Enum.map(fn {name, value} -> ~s(  "#{name}": "#{value}") end)
      |> List.insert_at(1, ~s(  "event": "#{subject}"))

    """
    Send this envelope (`bridge.*` subjects do the wrapping for you):

    {
    #{Enum.join(fields, ",\n")},
      "payload": #{payload}
    }
    """
    |> String.trim_trailing()
  end

  defp door_hint(nil, _payload, _subject), do: nil

  defp door_hint(door, payload, _subject) do
    "Or send plain JSON to `#{door}`: #{payload}"
  end
end

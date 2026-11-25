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

  The reply also echoes back what the rejected message *did* say about its
  sender (`source`, `source_node`, `triggered_by`, `event_id`, tenant/user), so
  a bad request can be traced to whoever sent it without grepping the bot log.
  When none of those fields are present the reply says so in as many words.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Reply

  @sender_fields ~w(source source_node triggered_by)
  @message_fields ~w(event_id event timestamp tenant_id user_id)
  @max_body_chars 400
  @max_value_chars 60

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
    * `:received` — the raw body that failed (JSON text or a map), echoed back
      for debugging
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
    received = Keyword.get(opts, :received)

    [
      headline(subject, reason),
      received_section(received),
      envelope(subject, payload),
      door_hint(door, payload, subject)
    ]
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

  defp received_section(nil), do: nil

  defp received_section(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = body} -> received_section(body)
      _ -> "Received (not JSON): #{truncate(raw, @max_body_chars)}"
    end
  end

  defp received_section(body) when is_map(body) do
    sender = describe(body, @sender_fields)
    message = describe(body, @message_fields)

    head =
      case sender do
        [] ->
          "Received, but the message does not name its sender " <>
            "(no source, source_node or triggered_by):"

        parts ->
          "Received from #{Enum.join(parts, " ")}:"
      end

    detail =
      case message do
        [] -> ""
        parts -> " — " <> Enum.join(parts, ", ")
      end

    head <> detail <> "\n  " <> truncate(Jason.encode!(body), @max_body_chars)
  end

  defp received_section(other), do: "Received: #{inspect(other)}"

  defp describe(body, fields) do
    for field <- fields,
        value = Map.get(body, field),
        not is_nil(value),
        value != "",
        do: "#{field}=#{short(value)}"
  end

  defp short(value) when is_binary(value), do: truncate(value, @max_value_chars)
  defp short(value), do: inspect(value)

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "…"
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

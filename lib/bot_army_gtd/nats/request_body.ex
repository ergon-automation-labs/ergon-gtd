defmodule BotArmyGtd.NATS.RequestBody do
  @moduledoc """
  Decodes a task request body in either of the two shapes the fleet sends.

  * an **event envelope** — `%{"event" => "gtd.task.create", "event_id" => ...,
    "payload" => %{"title" => ...}}`, validated against
    `/etc/bot_army/schemas/core/`
  * **plain JSON** — `%{"title" => ..., "priority" => ...}`, the shape
    `bot_army_claude_bridge` sends for `gtd.task.*` and the shape
    `gtd.task.list` / `gtd.task.get` / `gtd.task.search` already accept

  Before this module, `gtd.task.create` was the only task subject that demanded
  an envelope: `bot_army_claude_bridge`'s `TaskManager.do_create/2` sends plain
  JSON, the strict decoder rejected it, and the bridge then wrapped that
  rejection in a success reply. The visible symptom was
  `bridge.task.create` answering `ok: true` with no task while
  `bot_army_sre` logged `Incident processed: task , investigation <id>` — every
  log incident was detected, investigated, and never filed.

  A plain body is only accepted when it carries a non-empty `"title"`, and it is
  presented to the rest of the pipeline as an envelope-shaped map (payload plus
  the tenant/user fields the pipeline reads from the top level).
  """

  alias BotArmyLibraryCore.NATS.Decoder

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    case Decoder.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, envelope_error} -> decode_plain(raw, envelope_error)
    end
  end

  def decode(raw), do: {:error, {:invalid_body, raw}}

  defp decode_plain(raw, envelope_error) do
    case Jason.decode(raw) do
      {:ok, plain} when is_map(plain) -> from_plain(plain, envelope_error)
      _ -> {:error, envelope_error}
    end
  end

  defp from_plain(plain, envelope_error) do
    case plain["title"] do
      title when is_binary(title) and title != "" ->
        {:ok,
         %{
           "tenant_id" => plain["tenant_id"],
           "user_id" => plain["user_id"],
           "payload" => plain
         }}

      _ ->
        {:error, envelope_error}
    end
  end
end

defmodule BotArmyGtd.EventBuilder do
  @moduledoc """
  Shared event envelope construction for GTD bot handlers.

  All handlers should use this module instead of building envelopes inline,
  ensuring consistent field ordering, naming, and inclusion across all events.
  """

  @doc """
  Build a standard event envelope.

  ## Options

    * `:tenant_id` - Tenant context (inferred from message if omitted)
    * `:user_id` - User context (inferred from message if omitted)
    * `:triggered_by` - Source of the trigger (default: "gtd.bot")
    * `:event_id` - Override event_id (default: auto-generated UUID)
  """
  def build_event(event_name, payload, opts \\ []) do
    %{
      "event" => event_name,
      "event_id" => opts[:event_id] || UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => opts[:triggered_by] || "gtd.bot",
      "schema_version" => "1.0",
      "tenant_id" => opts[:tenant_id],
      "user_id" => opts[:user_id],
      "payload" => payload
    }
  end

  @doc """
  Build a standard error event envelope.

  Includes the original event_id that triggered the error for traceability.
  """
  def build_error(triggered_by_event_id, reason, message, opts \\ []) do
    payload = %{
      "error" => message,
      "reason" => inspect(reason),
      "triggered_by_event_id" => triggered_by_event_id
    }

    build_event("gtd.error", payload, opts)
  end
end

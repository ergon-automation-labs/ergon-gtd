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

  # Cross-bot consumers read a task's identity off the ENVELOPE ROOT, not out of
  # `payload["task"]`. `BotArmyRpg.ProgressionSubscriber` links an RPG quest to a
  # GTD task by root `task_id`, names the quest from root `task_title`, and sizes
  # the XP from root `priority`.
  @task_lifecycle_events ~w(gtd.task.created gtd.task.completed)

  @doc """
  Build the envelope for a task lifecycle event — the one true way.

  The payload is `%{"task" => task}` merged with `extra_payload` (so handlers can
  add their own context), and the task's identity is flattened onto the root for
  the events cross-bot consumers subscribe to.

  **Use this for `gtd.task.created` / `gtd.task.completed`; never `build_event/3`.**
  An envelope that only nests the task under `payload["task"]` looks correct in the
  store and reads correctly from inside GTD, while the consumer sees nothing: the
  quest linked to that task is never completed, and a newly created task never
  spawns a quest at all. That failure is silent on both sides — the producer thinks
  it published, the consumer thinks there was nothing to do.
  """
  def build_task_event(event_name, task, extra_payload \\ %{}, opts \\ []) do
    build_event(event_name, Map.merge(%{"task" => task}, extra_payload), opts)
    |> with_task_identity(task)
  end

  defp with_task_identity(%{"event" => event} = event_data, task)
       when event in @task_lifecycle_events do
    event_data
    |> Map.put("priority", Map.get(task, "priority", "normal"))
    |> Map.put("task_id", Map.get(task, "id"))
    |> Map.put("task_title", Map.get(task, "title", ""))
  end

  defp with_task_identity(event_data, _task), do: event_data
end

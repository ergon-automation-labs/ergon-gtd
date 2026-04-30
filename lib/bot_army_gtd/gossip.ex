defmodule BotArmyGtd.Gossip do
  @moduledoc """
  Topic-agnostic gossip participation for the GTD bot.

  GTD responds to utility intent proposals and social invites using
  lightweight heuristics from current task state.
  """

  require Logger

  def handle_intent_proposed(message) when is_map(message) do
    payload = Map.get(message, "payload", %{})
    intent_key = Map.get(payload, "intent_key", "")
    summary = Map.get(payload, "summary", "")
    conversation_id = Map.get(message, "conversation_id", "")

    {stance, reason, suggested_task_ids} = stance_for(summary)

    answer = %{
      "event_id" => UUID.uuid4(),
      "event" => "gossip.intent.answer",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "tenant_id" => Map.get(message, "tenant_id", "00000000-0000-0000-0000-000000000001"),
      "conversation_id" => conversation_id,
      "payload" => %{
        "intent_key" => intent_key,
        "responder" => "gtd_bot",
        "stance" => stance,
        "reason" => reason,
        "suggested_task_ids" => suggested_task_ids
      }
    }

    Logger.info("[GTD Gossip] intent answer stance=#{stance} intent_key=#{intent_key}")
    BotArmyRuntime.NATS.Publisher.publish("gossip.intent.answer", answer)
  end

  def handle_social_invite(message) when is_map(message) do
    payload = Map.get(message, "payload", %{})
    from_bot = Map.get(payload, "from_bot", "unknown")
    to_bot = Map.get(payload, "to_bot", "gtd_bot")
    accepted = social_accept?()

    reply = %{
      "event_id" => UUID.uuid4(),
      "event" => "gossip.social.reply",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "tenant_id" => Map.get(message, "tenant_id", "00000000-0000-0000-0000-000000000001"),
      "conversation_id" => Map.get(message, "conversation_id", UUID.uuid4()),
      "payload" => %{
        "from_bot" => to_bot,
        "to_bot" => from_bot,
        "accepted" => accepted,
        "reason" => if(accepted, do: "accepted_low_load_window", else: "declined_focus_window")
      }
    }

    Logger.info("[GTD Gossip] social invite from=#{from_bot} accepted=#{accepted}")
    BotArmyRuntime.NATS.Publisher.publish("gossip.social.reply", reply)
  end

  defp stance_for(summary) do
    active_count = active_task_count()
    low_summary = String.downcase(summary || "")

    cond do
      active_count >= 15 and String.contains?(low_summary, "brain") ->
        {"already_have_equivalent", "GTD already tracks many related active tasks.",
         top_task_ids(3)}

      active_count >= 10 ->
        {"need_more_context", "Need owner and desired outcome before creating another task.",
         top_task_ids(2)}

      true ->
        {"safe_to_create", "No heavy overlap detected from current active set.", []}
    end
  end

  defp active_task_count do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    case task_store.list_prioritized(tenant_id, %{"status" => "active"}) do
      {:ok, tasks} when is_list(tasks) -> length(tasks)
      _ -> 0
    end
  end

  defp top_task_ids(limit) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    case task_store.list_prioritized(tenant_id, %{"status" => "active"}) do
      {:ok, tasks} ->
        tasks
        |> Enum.take(limit)
        |> Enum.map(&Map.get(&1, "id"))
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  end

  defp social_accept? do
    active_count = active_task_count()
    active_count < 30 and :rand.uniform() < 0.4
  end
end

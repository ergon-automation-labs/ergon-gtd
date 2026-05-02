defmodule BotArmyGtd.Gossip do
  @moduledoc """
  Topic-agnostic gossip participation for the GTD bot.

  GTD responds to utility intent proposals and social invites using
  lightweight heuristics from current task state.
  """

  require Logger

  @table :gtd_gossip_poll_state

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

  def handle_poll_broadcast(message) when is_map(message) do
    ensure_table!()
    payload = Map.get(message, "payload", %{})
    poll_id = Map.get(payload, "poll_id")
    topic = Map.get(payload, "topic", "unknown")
    ttl_seconds = Map.get(payload, "ttl_seconds", 60)

    if is_binary(poll_id) and poll_id != "" do
      expires_at = System.system_time(:second) + ttl_seconds

      :ets.insert(
        @table,
        {:active_poll, %{poll_id: poll_id, topic: topic, expires_at: expires_at}}
      )

      Logger.info("[GTD Gossip] tracked poll broadcast poll_id=#{poll_id} topic=#{topic}")
    end
  end

  def maybe_vote_on_heartbeat do
    ensure_table!()

    case :ets.lookup(@table, :active_poll) do
      [{:active_poll, %{poll_id: poll_id, topic: topic, expires_at: expires_at}}] ->
        now = System.system_time(:second)
        voted_key = {:voted, poll_id}

        cond do
          now > expires_at ->
            :ets.delete(@table, :active_poll)
            :ok

          :ets.lookup(@table, voted_key) != [] ->
            :ok

          true ->
            publish_poll_vote(poll_id, topic)
            :ets.insert(@table, {voted_key, true})
        end

      _ ->
        :ok
    end

    maybe_vote_on_gtd_poll()
  end

  def handle_gtd_poll_broadcast(message) when is_map(message) do
    ensure_table!()
    payload = Map.get(message, "payload", message)
    poll_id = Map.get(payload, "poll_id")
    choices = Map.get(payload, "choices", %{})
    budget = Map.get(payload, "vote_budget_per_bot", 3)
    tenant_id = Map.get(payload, "tenant_id", BotArmyRuntime.Tenant.default_tenant_id())

    if is_binary(poll_id) and poll_id != "" do
      :ets.insert(
        @table,
        {:active_gtd_poll,
         %{poll_id: poll_id, choices: choices, budget: budget, tenant_id: tenant_id}}
      )

      Logger.info("[GTD Gossip] tracked GTD poll broadcast poll_id=#{poll_id}")
    end
  end

  def maybe_vote_on_gtd_poll do
    ensure_table!()

    case :ets.lookup(@table, :active_gtd_poll) do
      [
        {:active_gtd_poll,
         %{poll_id: poll_id, choices: choices, budget: budget, tenant_id: tenant_id}}
      ] ->
        voted_key = {:gtd_poll_voted, poll_id}

        if :ets.lookup(@table, voted_key) == [] do
          allocations = BotArmyRuntime.GtdPollAllocator.allocate(choices, :gtd, budget)

          if allocations != [] do
            submit_gtd_vote(poll_id, allocations, tenant_id)
          end

          :ets.insert(@table, {voted_key, true})
        end

      _ ->
        :ok
    end
  end

  defp submit_gtd_vote(poll_id, allocations, tenant_id) do
    payload = %{
      "poll_id" => poll_id,
      "voter_type" => "bot",
      "voter_id" => "gtd",
      "allocations" => allocations,
      "tenant_id" => tenant_id
    }

    # Call handler directly — GTD bot serves gtd.poll.vote.submit,
    # so NATS request/reply would deadlock (GenServer calling itself).
    case BotArmyGtd.Handlers.PollVoteHandler.handle_submit(payload) do
      {:ok, result} ->
        Logger.info("[GTD Gossip] submitted GTD poll vote poll_id=#{poll_id}")

      {:error, reason} ->
        Logger.warning(
          "[GTD Gossip] GTD poll vote failed poll_id=#{poll_id} reason=#{inspect(reason)}"
        )

        if poll_closed_error?(reason) do
          :ets.delete(@table, :active_gtd_poll)
        end
    end
  end

  defp poll_closed_error?(reason) when is_binary(reason),
    do: String.contains?(reason, "poll_not_open")

  defp poll_closed_error?(%{"error" => _}), do: true
  defp poll_closed_error?(_), do: false

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

  defp publish_poll_vote(poll_id, topic) do
    vote_message = %{
      "event_id" => UUID.uuid4(),
      "event" => "gossip.poll.vote",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "tenant_id" => BotArmyRuntime.Tenant.default_tenant_id(),
      "conversation_id" => poll_id,
      "payload" => %{
        "poll_id" => poll_id,
        "topic" => topic,
        "voter" => "gtd_bot",
        "vote" => vote_for(topic),
        "reason" => "voted_on_heartbeat_wakeup"
      }
    }

    BotArmyRuntime.NATS.Publisher.publish("gossip.poll.vote", vote_message)
    Logger.info("[GTD Gossip] emitted poll vote poll_id=#{poll_id}")
  end

  defp vote_for(topic) do
    active_count = active_task_count()

    case {topic, active_count} do
      {"priorities", count} when count > 20 -> "downvote"
      {"focus", count} when count > 15 -> "downvote"
      _ -> "upvote"
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _ -> :ok
    end
  end
end

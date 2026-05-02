defmodule BotArmyGtd.Handlers.PollCloseHandler do
  require Logger

  defp poll_round_store do
    Application.get_env(:bot_army_gtd, :poll_round_store, BotArmyGtd.PollRoundStore)
  end

  defp poll_vote_store do
    Application.get_env(:bot_army_gtd, :poll_vote_store, BotArmyGtd.PollVoteStore)
  end

  def handle_close(message) do
    params = message["payload"] || message

    tenant_id =
      params["tenant_id"] || message["tenant_id"] ||
        BotArmyRuntime.Tenant.default_tenant_id()

    poll_id = params["poll_id"]

    with {:ok, _poll} <- get_poll(tenant_id, poll_id),
         {:ok, closed_poll} <- poll_round_store().close(tenant_id, poll_id),
         {:ok, vote_totals} <- poll_vote_store().vote_totals_by_poll(tenant_id, poll_id) do
      materialize_signals(tenant_id, poll_id, vote_totals)
      BotArmyGtd.ScoreEngine.recompute_from_vote_totals(tenant_id, vote_totals)
      publish_poll_closed(closed_poll)

      {:ok, %{"poll_id" => poll_id, "status" => "closed"}}
    end
  end

  defp get_poll(tenant_id, poll_id) do
    case poll_round_store().get(tenant_id, poll_id) do
      {:ok, poll} -> {:ok, poll}
      {:error, :not_found} -> {:error, :poll_not_found}
    end
  end

  defp materialize_signals(tenant_id, poll_id, vote_totals) do
    Enum.each(vote_totals, fn total ->
      try do
        %BotArmyGtd.Schemas.ItemSignal{id: Ecto.UUID.generate()}
        |> BotArmyGtd.Schemas.ItemSignal.changeset(%{
          "item_type" => total["item_type"],
          "item_id" => total["item_id"],
          "signal_type" => "poll_vote",
          "signal_value" => total["total_votes"] * 1.0,
          "source" => "poll_round:#{poll_id}",
          "tenant_id" => tenant_id
        })
        |> BotArmyGtd.Repo.insert()
      rescue
        e -> Logger.warning("Failed to materialize signal: #{inspect(e)}")
      end
    end)
  end

  defp publish_poll_closed(poll) do
    try do
      BotArmyRuntime.NATS.Publisher.publish("gtd.poll.closed", %{
        "poll_id" => poll["id"],
        "name" => poll["name"],
        "tenant_id" => poll["tenant_id"],
        "status" => "closed"
      })
    rescue
      _ -> Logger.warning("Failed to publish gtd.poll.closed event")
    end
  end
end

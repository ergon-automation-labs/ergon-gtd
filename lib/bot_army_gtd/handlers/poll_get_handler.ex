defmodule BotArmyGtd.Handlers.PollGetHandler do
  require Logger

  defp poll_round_store do
    Application.get_env(:bot_army_gtd, :poll_round_store, BotArmyGtd.PollRoundStore)
  end

  defp poll_vote_store do
    Application.get_env(:bot_army_gtd, :poll_vote_store, BotArmyGtd.PollVoteStore)
  end

  def handle_get(message) do
    params = message["payload"] || message

    tenant_id =
      params["tenant_id"] || message["tenant_id"] ||
        Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    poll_id = params["poll_id"]

    with {:ok, poll} <- get_poll(tenant_id, poll_id),
         {:ok, vote_totals} <- poll_vote_store().vote_totals_by_poll(tenant_id, poll_id),
         {:ok, all_votes} <- poll_vote_store().list_by_poll(tenant_id, poll_id) do
      voters =
        all_votes
        |> Enum.map(fn v -> {v["voter_type"], v["voter_id"]} end)
        |> Enum.uniq()
        |> length()

      {:ok,
       %{
         "poll" => poll,
         "vote_totals" => vote_totals,
         "participation" => %{
           "voter_count" => voters,
           "total_votes" => length(all_votes)
         }
       }}
    end
  end

  defp get_poll(tenant_id, poll_id) do
    case poll_round_store().get(tenant_id, poll_id) do
      {:ok, poll} -> {:ok, poll}
      {:error, :not_found} -> {:error, :poll_not_found}
    end
  end
end

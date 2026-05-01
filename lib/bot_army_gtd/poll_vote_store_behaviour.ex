defmodule BotArmyGtd.PollVoteStoreBehaviour do
  @callback submit(payload :: map()) :: {:ok, map()} | {:error, term()}
  @callback list_by_poll(tenant_id :: String.t(), poll_id :: String.t()) :: {:ok, [map()]}
  @callback total_votes_by_voter(
              tenant_id :: String.t(),
              poll_id :: String.t(),
              voter_type :: String.t(),
              voter_id :: String.t()
            ) ::
              {:ok, integer()}
  @callback vote_totals_by_poll(tenant_id :: String.t(), poll_id :: String.t()) :: {:ok, [map()]}
  @callback clear() :: :ok
end

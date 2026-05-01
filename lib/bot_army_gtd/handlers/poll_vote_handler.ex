defmodule BotArmyGtd.Handlers.PollVoteHandler do
  require Logger

  defp poll_round_store do
    Application.get_env(:bot_army_gtd, :poll_round_store, BotArmyGtd.PollRoundStore)
  end

  defp poll_vote_store do
    Application.get_env(:bot_army_gtd, :poll_vote_store, BotArmyGtd.PollVoteStore)
  end

  def handle_submit(message) do
    params = message["payload"] || message

    tenant_id =
      params["tenant_id"] || message["tenant_id"] ||
        Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    poll_id = params["poll_id"]
    voter_type = params["voter_type"]
    voter_id = params["voter_id"]
    allocations = params["allocations"] || []

    with :ok <- validate_required_fields(poll_id, voter_type, voter_id),
         :ok <- validate_voter_type(voter_type),
         {:ok, poll} <- get_poll(tenant_id, poll_id),
         :ok <- validate_poll_open(poll),
         :ok <- validate_budget(poll, tenant_id, voter_type, voter_id, allocations),
         :ok <- validate_allocations_in_snapshot(allocations, poll) do
      results =
        Enum.map(allocations, fn alloc ->
          payload = %{
            "poll_id" => poll_id,
            "voter_type" => voter_type,
            "voter_id" => voter_id,
            "item_type" => Map.get(alloc, "item_type"),
            "item_id" => Map.get(alloc, "item_id"),
            "votes" => Map.get(alloc, "votes", 1)
          }

          poll_vote_store().submit(payload)
        end)

      accepted =
        Enum.all?(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      total_cast = Enum.sum(Enum.map(allocations, &(&1["votes"] || 1)))

      {:ok,
       %{
         "poll_id" => poll_id,
         "voter_id" => voter_id,
         "total_votes_cast" => total_cast,
         "accepted" => accepted
       }}
    end
  end

  defp validate_required_fields(nil, _, _), do: {:error, :poll_id_required}
  defp validate_required_fields(_, nil, _), do: {:error, :voter_type_required}
  defp validate_required_fields(_, _, nil), do: {:error, :voter_id_required}
  defp validate_required_fields(_, _, ""), do: {:error, :voter_id_required}
  defp validate_required_fields(_, _, _), do: :ok

  defp validate_voter_type(t) when t in ["bot", "human"], do: :ok
  defp validate_voter_type(_), do: {:error, :invalid_voter_type}

  defp get_poll(tenant_id, poll_id) do
    case poll_round_store().get(tenant_id, poll_id) do
      {:ok, poll} -> {:ok, poll}
      {:error, :not_found} -> {:error, :poll_not_found}
    end
  end

  defp validate_poll_open(%{"status" => "open"}), do: :ok
  defp validate_poll_open(_), do: {:error, :poll_not_open}

  defp validate_budget(poll, tenant_id, voter_type, voter_id, allocations) do
    budget = poll["vote_budget_per_bot"] || 3
    requested = Enum.sum(Enum.map(allocations, &(&1["votes"] || 1)))

    {:ok, already_spent} =
      poll_vote_store().total_votes_by_voter(tenant_id, poll["id"], voter_type, voter_id)

    if already_spent + requested <= budget do
      :ok
    else
      {:error, :over_budget}
    end
  end

  defp validate_allocations_in_snapshot(allocations, poll) do
    snapshot = poll["snapshot"] || %{}

    Enum.all?(allocations, fn alloc ->
      item_type = Map.get(alloc, "item_type")
      item_id = Map.get(alloc, "item_id")
      type_list = Map.get(snapshot, item_type, [])
      item_id in type_list
    end)
    |> if(do: :ok, else: {:error, :item_not_in_snapshot})
  end
end

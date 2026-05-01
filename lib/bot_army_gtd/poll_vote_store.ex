defmodule BotArmyGtd.PollVoteStore do
  use GenServer
  require Logger

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def submit(payload) when is_map(payload) do
    GenServer.call(@server, {:submit, payload})
  end

  def list_by_poll(tenant_id, poll_id) when is_binary(tenant_id) and is_binary(poll_id) do
    GenServer.call(@server, {:list_by_poll, tenant_id, poll_id})
  end

  def total_votes_by_voter(tenant_id, poll_id, voter_type, voter_id)
      when is_binary(tenant_id) and is_binary(poll_id) and is_binary(voter_type) and
             is_binary(voter_id) do
    GenServer.call(@server, {:total_votes_by_voter, tenant_id, poll_id, voter_type, voter_id})
  end

  def vote_totals_by_poll(tenant_id, poll_id)
      when is_binary(tenant_id) and is_binary(poll_id) do
    GenServer.call(@server, {:vote_totals_by_poll, tenant_id, poll_id})
  end

  def clear do
    GenServer.call(@server, :clear)
  end

  @impl true
  def init(_opts) do
    state =
      try do
        votes = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.PollVote)

        Enum.reduce(votes, %{}, fn vote, acc ->
          Map.put(acc, to_string(vote.id), schema_to_map(vote))
        end)
      rescue
        _ ->
          Logger.warning("Could not load poll votes from database. Starting with empty state.")
          %{}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, payload}, _from, state) do
    poll_id = Map.get(payload, "poll_id")
    voter_type = Map.get(payload, "voter_type")
    voter_id = Map.get(payload, "voter_id")
    item_type = Map.get(payload, "item_type")
    item_id = Map.get(payload, "item_id")
    votes = Map.get(payload, "votes", 1)

    changeset =
      BotArmyGtd.Schemas.PollVote.changeset(
        %BotArmyGtd.Schemas.PollVote{id: Ecto.UUID.generate()},
        %{
          "poll_id" => poll_id,
          "voter_type" => voter_type,
          "voter_id" => voter_id,
          "item_type" => item_type,
          "item_id" => item_id,
          "votes" => votes
        }
      )

    case BotArmyGtd.Repo.insert(changeset) do
      {:ok, vote} ->
        vote_map = schema_to_map(vote)
        {:reply, {:ok, vote_map}, Map.put(state, to_string(vote.id), vote_map)}

      {:error, changeset} ->
        {:reply, {:error, changeset_error_reason(changeset)}, state}
    end
  end

  @impl true
  def handle_call({:list_by_poll, tenant_id, poll_id}, _from, state) do
    votes =
      state
      |> Map.values()
      |> Enum.filter(fn vote ->
        vote["poll_id"] == poll_id
      end)

    {:reply, {:ok, votes}, state}
  end

  @impl true
  def handle_call({:total_votes_by_voter, tenant_id, poll_id, voter_type, voter_id}, _from, state) do
    total =
      state
      |> Map.values()
      |> Enum.filter(fn vote ->
        vote["poll_id"] == poll_id and
          vote["voter_type"] == voter_type and
          vote["voter_id"] == voter_id
      end)
      |> Enum.reduce(0, fn vote, acc -> acc + (vote["votes"] || 1) end)

    {:reply, {:ok, total}, state}
  end

  @impl true
  def handle_call({:vote_totals_by_poll, tenant_id, poll_id}, _from, state) do
    totals =
      state
      |> Map.values()
      |> Enum.filter(fn vote -> vote["poll_id"] == poll_id end)
      |> Enum.group_by(fn vote -> {vote["item_type"], vote["item_id"]} end)
      |> Enum.map(fn {{item_type, item_id}, votes} ->
        %{
          "item_type" => item_type,
          "item_id" => item_id,
          "total_votes" => Enum.reduce(votes, 0, fn v, acc -> acc + (v["votes"] || 1) end),
          "voter_count" => length(Enum.uniq_by(votes, & &1["voter_id"]))
        }
      end)

    {:reply, {:ok, totals}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    try do
      BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.PollVote)
    rescue
      _ -> :ok
    end

    {:reply, :ok, %{}}
  end

  defp schema_to_map(%BotArmyGtd.Schemas.PollVote{} = vote) do
    %{
      "id" => to_string(vote.id),
      "poll_id" => to_string(vote.poll_id),
      "voter_type" => vote.voter_type,
      "voter_id" => vote.voter_id,
      "item_type" => vote.item_type,
      "item_id" => to_string(vote.item_id),
      "votes" => vote.votes,
      "inserted_at" => vote.inserted_at && DateTime.to_iso8601(vote.inserted_at),
      "updated_at" => vote.updated_at && DateTime.to_iso8601(vote.updated_at)
    }
  end

  defp changeset_error_reason(%Ecto.Changeset{} = changeset) do
    {:validation_error, Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp changeset_error_reason(_), do: :database_error

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end

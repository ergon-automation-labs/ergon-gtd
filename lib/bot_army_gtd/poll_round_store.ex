defmodule BotArmyGtd.PollRoundStore do
  use GenServer
  require Logger

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  def get(tenant_id, poll_id) when is_binary(tenant_id) and is_binary(poll_id) do
    GenServer.call(@server, {:get, tenant_id, poll_id})
  end

  def get_open(tenant_id) when is_binary(tenant_id) do
    GenServer.call(@server, {:get_open, tenant_id})
  end

  def close(tenant_id, poll_id) when is_binary(tenant_id) and is_binary(poll_id) do
    GenServer.call(@server, {:close, tenant_id, poll_id})
  end

  def list(tenant_id, filters \\ %{}) when is_binary(tenant_id) and is_map(filters) do
    GenServer.call(@server, {:list, tenant_id, filters})
  end

  def clear do
    GenServer.call(@server, :clear)
  end

  @impl true
  def init(_opts) do
    state =
      try do
        rounds = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.PollRound)

        Enum.reduce(rounds, %{}, fn round, acc ->
          Map.put(acc, round.id |> to_string(), schema_to_map(round))
        end)
      rescue
        _ ->
          Logger.warning("Could not load poll rounds from database. Starting with empty state.")
          %{}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    poll_id = Ecto.UUID.generate()
    tenant_id = payload["tenant_id"]
    user_id = Map.get(payload, "user_id")

    closes_at =
      case Map.get(payload, "closes_at") do
        nil -> nil
        s when is_binary(s) -> parse_datetime(s)
        _ -> nil
      end

    changeset =
      BotArmyGtd.Schemas.PollRound.changeset(
        %BotArmyGtd.Schemas.PollRound{id: poll_id},
        %{
          "tenant_id" => convert_to_uuid(tenant_id),
          "user_id" => if(user_id, do: convert_to_uuid(user_id), else: nil),
          "name" => payload["name"],
          "vote_budget_per_bot" => Map.get(payload, "vote_budget_per_bot", 3),
          "snapshot_json" => Map.get(payload, "snapshot"),
          "status" => "open",
          "closes_at" => closes_at
        }
      )

    case BotArmyGtd.Repo.insert(changeset) do
      {:ok, round} ->
        round_map = schema_to_map(round)
        {:reply, {:ok, round_map}, Map.put(state, poll_id, round_map)}

      {:error, changeset} ->
        {:reply, {:error, changeset_error_reason(changeset)}, state}
    end
  end

  @impl true
  def handle_call({:get, tenant_id, poll_id}, _from, state) do
    case Map.get(state, poll_id) do
      nil -> {:reply, {:error, :not_found}, state}
      round -> {:reply, {:ok, round}, state}
    end
  end

  @impl true
  def handle_call({:get_open, tenant_id}, _from, state) do
    result =
      state
      |> Map.values()
      |> Enum.find(fn round ->
        round["tenant_id"] == tenant_id and round["status"] == "open"
      end)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:close, tenant_id, poll_id}, _from, state) do
    case Map.get(state, poll_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      round ->
        case BotArmyGtd.Repo.get(BotArmyGtd.Schemas.PollRound, poll_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          db_round ->
            changeset = BotArmyGtd.Schemas.PollRound.changeset(db_round, %{"status" => "closed"})

            case BotArmyGtd.Repo.update(changeset) do
              {:ok, updated} ->
                updated_map = schema_to_map(updated)
                {:reply, {:ok, updated_map}, Map.put(state, poll_id, updated_map)}

              {:error, changeset} ->
                {:reply, {:error, changeset_error_reason(changeset)}, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:list, tenant_id, filters}, _from, state) do
    rounds =
      state
      |> Map.values()
      |> Enum.filter(fn round -> round["tenant_id"] == tenant_id end)
      |> apply_filters(filters)

    {:reply, {:ok, rounds}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    try do
      BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.PollRound)
    rescue
      _ -> :ok
    end

    {:reply, :ok, %{}}
  end

  defp apply_filters(rounds, filters) do
    Enum.filter(rounds, fn round ->
      Enum.all?(filters, fn
        {"status", status} -> round["status"] == status
        _ -> true
      end)
    end)
  end

  defp schema_to_map(%BotArmyGtd.Schemas.PollRound{} = round) do
    %{
      "id" => to_string(round.id),
      "name" => round.name,
      "vote_budget_per_bot" => round.vote_budget_per_bot,
      "snapshot" => round.snapshot_json,
      "status" => round.status,
      "closes_at" => round.closes_at && to_iso8601(round.closes_at),
      "tenant_id" => to_string(round.tenant_id),
      "user_id" => round.user_id && to_string(round.user_id),
      "inserted_at" => round.inserted_at && to_iso8601(round.inserted_at),
      "updated_at" => round.updated_at && to_iso8601(round.updated_at)
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

  defp convert_to_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> generate_uuid_from_string(value)
    end
  end

  defp convert_to_uuid(value), do: value

  defp generate_uuid_from_string(string) when is_binary(string) do
    hash = :crypto.hash(:sha256, string)
    <<uuid_int::128>> = binary_part(hash, 0, 16)
    <<uuid_int::128>> |> Ecto.UUID.cast() |> elem(1)
  end

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end

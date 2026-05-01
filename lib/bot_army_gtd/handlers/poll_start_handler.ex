defmodule BotArmyGtd.Handlers.PollStartHandler do
  require Logger

  defp poll_round_store do
    Application.get_env(:bot_army_gtd, :poll_round_store, BotArmyGtd.PollRoundStore)
  end

  def handle_create(message) do
    params = message["payload"] || message

    tenant_id =
      params["tenant_id"] || message["tenant_id"] ||
        Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    name = params["name"]
    snapshot = params["snapshot"]
    vote_budget = Map.get(params, "vote_budget_per_bot", 3)

    with :ok <- validate_name(name),
         :ok <- validate_snapshot(snapshot),
         :ok <- enforce_one_open_poll(tenant_id) do
      payload = %{
        "name" => name,
        "snapshot" => snapshot,
        "vote_budget_per_bot" => vote_budget,
        "tenant_id" => tenant_id,
        "user_id" => Map.get(params, "user_id") || Map.get(message, "user_id"),
        "closes_at" => Map.get(params, "closes_at") || Map.get(message, "closes_at")
      }

      case poll_round_store().create(payload) do
        {:ok, poll} ->
          Logger.info("Poll created: poll_id=#{poll["id"]}, name=#{name}")
          publish_poll_created(poll)
          {:ok, poll}

        {:error, reason} ->
          Logger.error("Failed to create poll: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp validate_name(nil), do: {:error, :name_required}
  defp validate_name(""), do: {:error, :name_required}
  defp validate_name(_), do: :ok

  defp validate_snapshot(nil), do: {:error, :snapshot_required}
  defp validate_snapshot(s) when is_map(s), do: :ok
  defp validate_snapshot(_), do: {:error, :snapshot_must_be_map}

  defp enforce_one_open_poll(tenant_id) do
    case poll_round_store().get_open(tenant_id) do
      {:ok, nil} -> :ok
      {:ok, _existing} -> {:error, :poll_already_open}
    end
  end

  defp publish_poll_created(poll) do
    try do
      BotArmyRuntime.NATS.Publisher.publish("gtd.poll.created", %{
        "poll_id" => poll["id"],
        "name" => poll["name"],
        "tenant_id" => poll["tenant_id"]
      })
    rescue
      _ -> Logger.warning("Failed to publish gtd.poll.created event")
    end
  end
end

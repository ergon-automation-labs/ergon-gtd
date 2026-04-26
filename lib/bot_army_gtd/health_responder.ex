defmodule BotArmyGtd.HealthResponder do
  @moduledoc """
  NATS request/reply handler for GTD bot health checks.

  Responds to `bot.gtd.health` requests with system status including
  NATS connectivity, database connectivity, key process liveness, and version.

  Re-registers with ConnectionRegistry on reconnect so the health subscription
  is always active.
  """

  use GenServer

  require Logger

  @reconnect_delay_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      bot_name: Keyword.fetch!(opts, :bot_name),
      repo: Keyword.get(opts, :repo),
      process_names: Keyword.get(opts, :process_names, []),
      version: Keyword.get(opts, :version, "unknown"),
      connection: nil,
      subscription: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case BotArmyRuntime.NATS.Connection.start_link([]) do
      {:error, {:already_started, _}} ->
        connect_existing(state)

      {:ok, _pid} ->
        connect_existing(state)

      {:error, reason} ->
        Logger.warning("[Health] NATS connection unavailable: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  defp connect_existing(state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} ->
        subject = "bot.#{state.bot_name}.health"

        case Gnat.sub(conn, self(), subject) do
          {:ok, subscription} ->
            BotArmyRuntime.NATS.Connection.subscribe_to_status()
            Logger.info("[Health] Subscribed to #{subject}")

            # Register health check subject with the registry
            health_subject = %{
              subject: subject,
              type: :request_reply,
              description: "Health check for #{state.bot_name} bot",
              timeout_ms: 5000
            }

            BotArmyRuntime.Registry.register(state.bot_name, [health_subject])

            {:noreply, %{state | connection: conn, subscription: subscription}}

          {:error, reason} ->
            Logger.warning("[Health] Failed to subscribe: #{inspect(reason)}")
            Process.send_after(self(), :reconnect, @reconnect_delay_ms)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("[Health] NATS not connected: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:msg, %{reply_to: reply_to}}, state) when not is_nil(reply_to) do
    health = %{
      status: compute_overall_status(state),
      bot: state.bot_name,
      version: state.version,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: %{
        nats: check_nats(),
        database: check_db(state.repo),
        processes: check_processes(state.process_names)
      }
    }

    payload = Jason.encode!(health)
    Gnat.pub(state.connection, reply_to, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, _msg}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[Health] NATS disconnected, scheduling reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | connection: nil, subscription: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[Health] NATS reconnected, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("[Health] Attempting NATS reconnect")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp compute_overall_status(state) do
    nats_ok = check_nats() == :ok
    db_ok = check_db(state.repo) == :ok or is_nil(state.repo)
    procs_ok = check_processes(state.process_names) == :ok

    cond do
      nats_ok and db_ok and procs_ok -> :healthy
      nats_ok and (db_ok or procs_ok) -> :degraded
      true -> :unhealthy
    end
  end

  defp check_nats do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp check_db(nil), do: :skip

  defp check_db(repo) do
    try do
      Logger.debug("[Health] Checking DB with repo: #{inspect(repo)}")
      Logger.debug("[Health] Ecto config: #{inspect(Ecto.Repo.Registry.lookup(BotArmyGtd.Repo))}")

      case repo.query("SELECT 1") do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("[Health] DB query error: #{inspect(reason)}")
          :error
      end
    rescue
      e ->
        Logger.error("[Health] DB query exception: #{inspect(e)}")
        :error
    end
  end

  defp check_processes([]), do: :ok

  defp check_processes(process_names) do
    all_alive =
      Enum.all?(process_names, fn name ->
        if is_pid(name) do
          Process.alive?(name)
        else
          GenServer.whereis(name) != nil
        end
      end)

    if all_alive, do: :ok, else: :error
  end
end

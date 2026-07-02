defmodule BotArmyGtd.LeaderMonitor do
  @moduledoc """
  Leader election for distributed GTD instances (air primary, mini standby).

  Air publishes heartbeats every 30 seconds. Mini monitors these heartbeats:
  - If heartbeat present: Mini is standby (read-only)
  - If no heartbeat for 90+ seconds: Mini becomes leader (can write)

  This enables high-availability when air becomes inaccessible.
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS

  @server __MODULE__
  @heartbeat_timeout_ms 90_000
  @health_check_interval_ms 10_000

  def start_link(opts) do
    node_role = Application.get_env(:bot_army_gtd, :node_role, :primary)
    GenServer.start_link(__MODULE__, {node_role, opts}, name: @server)
  end

  def is_leader? do
    try do
      GenServer.call(@server, :is_leader?, 5_000)
    rescue
      _ -> false
    end
  end

  def get_role do
    try do
      GenServer.call(@server, :get_role, 5_000)
    rescue
      _ -> :unknown
    end
  end

  def get_status do
    try do
      GenServer.call(@server, :get_status, 5_000)
    rescue
      _ -> %{role: :unknown, is_leader: false, last_heartbeat: nil}
    end
  end

  @impl true
  def init({node_role, _opts}) do
    # Allow environment variable to override config file
    node_role =
      case System.get_env("GTD_NODE_ROLE") do
        "standby" -> :standby
        "primary" -> :primary
        _ -> node_role
      end

    Logger.info("[LeaderMonitor] Starting with node_role=#{node_role}")

    state = %{
      node_role: node_role,
      is_leader: node_role == :primary,
      last_heartbeat_ms: System.monotonic_time(:millisecond),
      heartbeat_timeout_ms: @heartbeat_timeout_ms
    }

    # Only standby nodes monitor for leader election
    if node_role == :standby do
      Process.send_after(self(), :check_heartbeat, @health_check_interval_ms)
      subscribe_to_health_updates()
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:is_leader?, _from, state) do
    {:reply, state.is_leader, state}
  end

  @impl true
  def handle_call(:get_role, _from, state) do
    {:reply, state.node_role, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      role: state.node_role,
      is_leader: state.is_leader,
      last_heartbeat: state.last_heartbeat_ms
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:heartbeat_received, state) do
    new_state = %{state | last_heartbeat_ms: System.monotonic_time(:millisecond)}

    if state.is_leader do
      Logger.info("[LeaderMonitor] Heartbeat from air detected, becoming standby")
    end

    {:noreply, %{new_state | is_leader: false}}
  end

  @impl true
  def handle_info(:check_heartbeat, state) do
    now_ms = System.monotonic_time(:millisecond)
    time_since_heartbeat = now_ms - state.last_heartbeat_ms

    was_leader = state.is_leader
    is_now_leader = time_since_heartbeat > state.heartbeat_timeout_ms

    if is_now_leader and not was_leader do
      Logger.warning(
        "[LeaderMonitor] No heartbeat for #{time_since_heartbeat}ms (timeout: #{state.heartbeat_timeout_ms}ms), BECOMING LEADER"
      )
    end

    if was_leader and not is_now_leader do
      Logger.info("[LeaderMonitor] Heartbeat restored, becoming standby")
    end

    Process.send_after(self(), :check_heartbeat, @health_check_interval_ms)
    {:noreply, %{state | is_leader: is_now_leader}}
  end

  defp subscribe_to_health_updates do
    Task.start_link(fn ->
      case NATS.Connection.get_connection() do
        {:ok, conn} ->
          Logger.debug("[LeaderMonitor] Subscribing to health updates from air GTD")

          {:ok, _sub} =
            Gnat.sub(
              conn,
              self(),
              "system.health.gtd",
              queue_group: "gtd-leader-monitor"
            )

        {:error, reason} ->
          Logger.warning("[LeaderMonitor] Failed to subscribe to health updates: #{reason}")
      end
    end)
  end
end

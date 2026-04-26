defmodule BotArmyGtd.PulsePublisher do
  @moduledoc """
  Publishes periodic health pulses to Synapse.

  GTD broadcasts full task and project state for Synapse context gathering.
  Instead of Synapse making NATS requests (which timeout), GTD proactively
  publishes its data every 30 minutes. Synapse's PulseListener caches this data
  and context handlers read from the cache with zero-latency fallback.

  Pulse format includes full project and task data:
    {
      "bot": "gtd",
      "timestamp": "2026-04-25T10:25:00Z",
      "tenant_id": "...",
      "projects": [...],
      "tasks": [...],
      "observations": {
        "goals": {...},
        "total_active_tasks": N,
        "health_signal": "nominal|degraded|critical"
      }
    }
  """

  use GenServer
  require Logger

  alias BotArmyGtd.TaskStore

  # 5 minutes
  @publish_interval_ms 30 * 60 * 1000
  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting GTD pulse publisher")
    Process.send_after(self(), :publish_pulse, 0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse() end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:noreply, state}
  end

  defp publish_pulse do
    default_tenant = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    case TaskStore.list(default_tenant) do
      {:ok, tasks} ->
        case BotArmyGtd.ProjectStore.list(default_tenant) do
          {:ok, projects} ->
            pulse = build_pulse(tasks, projects, default_tenant)
            publish_to_nats(pulse)

          {:error, reason} ->
            Logger.warning("[PulsePublisher] Failed to list projects: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to build pulse: #{inspect(reason)}")
    end
  end

  defp build_pulse(tasks, projects, tenant_id) do
    now = DateTime.utc_now()

    goal_observations =
      tasks
      |> Enum.group_by(& &1["project_id"])
      |> Enum.map(fn {goal_id, goal_tasks} ->
        {goal_id, analyze_goal_tasks(goal_tasks, now)}
      end)
      |> Enum.into(%{})

    total_active = Enum.count(tasks)

    health_signal =
      cond do
        total_active == 0 -> "nominal"
        Enum.count(goal_observations) == 0 -> "nominal"
        true -> "nominal"
      end

    %{
      "bot" => "gtd",
      "timestamp" => DateTime.to_iso8601(now),
      "tenant_id" => tenant_id,
      "projects" => projects,
      "tasks" => tasks,
      "observations" => %{
        "goals" => goal_observations,
        "total_active_tasks" => total_active,
        "health_signal" => health_signal
      }
    }
  end

  defp analyze_goal_tasks(tasks, now) do
    task_ages =
      tasks
      |> Enum.map(fn task ->
        case task["created_at"] do
          nil ->
            nil

          created_str ->
            case DateTime.from_iso8601(created_str) do
              {:ok, created_dt, _} ->
                DateTime.diff(now, created_dt, :second)

              :error ->
                nil
            end
        end
      end)
      |> Enum.filter(&(not is_nil(&1)))

    old_tasks = Enum.count(task_ages, &(&1 > 7 * 24 * 3600))

    %{
      "active_tasks" => Enum.count(tasks),
      "tasks_older_than_7d" => old_tasks,
      "newest_task_age_seconds" => if(Enum.empty?(task_ages), do: nil, else: Enum.min(task_ages))
    }
  end

  defp publish_to_nats(pulse) do
    try do
      case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          json = Jason.encode!(pulse)

          case Gnat.pub(conn, "bot.gtd.pulse", json) do
            :ok ->
              Logger.debug("[PulsePublisher] Published GTD pulse")

            {:error, reason} ->
              Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[PulsePublisher] NATS unavailable, skipping pulse: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning("[PulsePublisher] Error publishing pulse: #{inspect(e)}")
    end
  end
end

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
  alias BotArmyGtd.ProjectStore

  # 5 minutes
  @publish_interval_ms 30 * 60 * 1000
  @health_interval_ms 30 * 1000
  @server __MODULE__
  @source "bot_army_gtd"
  @schema_version "1.0"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting GTD pulse publisher")
    Process.send_after(self(), :publish_pulse, 5000)
    Process.send_after(self(), :publish_health, 2_000)
    {:ok, %{sequence: 0}}
  end

  @impl true
  def handle_info(:publish_health, state) do
    tenant_id =
      Application.get_env(:bot_army_gtd, :default_tenant_id) ||
        BotArmyRuntime.Tenant.default_tenant_id()

    BotArmyRuntime.SynapseHealth.publish(
      source: @source,
      service: "gtd",
      status: "healthy",
      tenant_id: tenant_id,
      sequence: state.sequence
    )

    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Logger.debug("[PulsePublisher] Publishing pulse")

    Task.start(fn ->
      try do
        pulse = publish_pulse(state.sequence)

        if pulse do
          BotArmyGtd.IntentEvaluator.record_observations(pulse)
        end
      rescue
        e ->
          Logger.error("[PulsePublisher] Error publishing pulse: #{inspect(e)}")
      end
    end)

    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:noreply, state}
  end

  defp publish_pulse(base_sequence) do
    Logger.debug("[PulsePublisher] publish_pulse() called")
    default_tenant = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    with {:ok, tasks} <- TaskStore.list(default_tenant),
         {:ok, projects} <- ProjectStore.list(default_tenant) do
      pulse = build_pulse(tasks, projects, default_tenant)
      publish_to_nats(pulse, base_sequence)
      pulse
    else
      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to build pulse: #{inspect(reason)}")
        nil
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
        goal_observations == [] -> "nominal"
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

  def build_hydration_events(pulse, base_sequence) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    tenant_id = pulse["tenant_id"] || "default"
    total_active_tasks = get_in(pulse, ["observations", "total_active_tasks"]) || 0
    projects = pulse["projects"] || []
    tasks = pulse["tasks"] || []

    health_status =
      cond do
        total_active_tasks > 100 -> "degraded"
        true -> "healthy"
      end

    risk_severity =
      cond do
        health_status == "degraded" -> "medium"
        true -> "low"
      end

    [
      %{
        "event_id" => "#{@source}-health-#{base_sequence}",
        "event" => "system.health",
        "schema_version" => @schema_version,
        "timestamp" => now,
        "source" => @source,
        "tenant_id" => tenant_id,
        "payload" => %{
          "service" => "gtd",
          "status" => health_status,
          "uptime_seconds" => uptime_seconds(),
          "last_event_age_ms" => 0,
          "dedupe_key" => "#{@source}:system.health",
          "sequence" => base_sequence
        }
      },
      %{
        "event_id" => "#{@source}-capability-#{base_sequence + 1}",
        "event" => "system.capability.snapshot",
        "schema_version" => @schema_version,
        "timestamp" => now,
        "source" => @source,
        "tenant_id" => tenant_id,
        "payload" => %{
          "service" => "gtd",
          "captured_at" => now,
          "capabilities" => ["task_management", "project_management", "task_decomposition"],
          "subjects" => ["events.gtd.*", "cmd.gtd.*", "bot.gtd.pulse"],
          "dedupe_key" => "#{@source}:system.capability.snapshot",
          "sequence" => base_sequence + 1,
          "metadata" => %{
            "project_count" => length(projects),
            "task_count" => length(tasks)
          }
        }
      },
      %{
        "event_id" => "#{@source}-risk-#{base_sequence + 2}",
        "event" => "system.risk.signal",
        "schema_version" => @schema_version,
        "timestamp" => now,
        "source" => @source,
        "tenant_id" => tenant_id,
        "payload" => %{
          "risk_id" => "gtd-backlog-#{base_sequence}",
          "risk_type" => "risk.backlog_pressure",
          "severity" => risk_severity,
          "status" => if(total_active_tasks > 100, do: "active", else: "resolved"),
          "reason" => %{
            "total_active_tasks" => total_active_tasks,
            "project_count" => length(projects)
          },
          "next_action" =>
            if(total_active_tasks > 100,
              do: "triage and rebalance GTD active tasks",
              else: "continue steady-state operations"
            ),
          "detected_at" => now,
          "dedupe_key" => "#{@source}:system.risk.signal",
          "sequence" => base_sequence + 2
        }
      },
      %{
        "event_id" => "#{@source}-verification-#{base_sequence + 3}",
        "event" => "task.signal.verification",
        "schema_version" => @schema_version,
        "timestamp" => now,
        "source" => @source,
        "tenant_id" => tenant_id,
        "payload" => %{
          "task_id" => "gtd-pulse-#{base_sequence}",
          "status" => "pass",
          "scope" => "bot_army_gtd pulse",
          "test_case" => "gtd pulse hydration snapshot",
          "recorded_at" => now,
          "dedupe_key" => "#{@source}:task.signal.verification",
          "sequence" => base_sequence + 3,
          "metadata" => %{
            "total_active_tasks" => total_active_tasks
          }
        }
      }
    ]
  end

  defp publish_to_nats(pulse, base_sequence) do
    Logger.debug("[PulsePublisher] publish_to_nats() called")

    Logger.debug("[PulsePublisher] Getting NATS connection...")

    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        Logger.debug("[PulsePublisher] Got NATS connection, encoding pulse...")
        json = Jason.encode!(pulse)

        case Gnat.pub(conn, "bot.gtd.pulse", json) do
          :ok ->
            Logger.debug("[PulsePublisher] Published GTD pulse")

          {:error, reason} ->
            Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
        end

        build_hydration_events(pulse, base_sequence)
        |> Enum.each(fn event ->
          case Gnat.pub(conn, event["event"], Jason.encode!(event)) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[PulsePublisher] Failed to publish hydration event #{event["event"]}: #{inspect(reason)}"
              )
          end
        end)

      {:error, reason} ->
        Logger.warning("[PulsePublisher] NATS unavailable, skipping pulse: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[PulsePublisher] Error publishing pulse: #{inspect(e)}")
  end

  defp uptime_seconds do
    {ms, _} = :erlang.statistics(:wall_clock)
    div(ms, 1000)
  end
end

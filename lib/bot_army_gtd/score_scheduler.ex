defmodule BotArmyGtd.ScoreScheduler do
  @moduledoc """
  Periodic scheduler that recomputes GTD item scores from signals.

  Runs every 5 minutes by default to keep "what's next" rankings fresh.
  Works in tandem with event-driven scoring in handlers for immediate updates.

  Configuration in config/config.exs:
    config :bot_army_gtd, BotArmyGtd.ScoreScheduler,
      enabled: true,
      interval_seconds: 300  # Every 5 minutes
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias BotArmyGtd.{Repo, ScoreEngine}
  alias BotArmyGtd.Schemas.{ItemSignal, ItemScore}

  @default_interval_seconds 300

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:bot_army_gtd, __MODULE__, [])[:enabled] || false

    interval =
      Application.get_env(:bot_army_gtd, __MODULE__, [])[:interval_seconds] ||
        @default_interval_seconds

    Logger.info("ScoreScheduler: enabled=#{enabled}, interval=#{interval}s")

    if enabled do
      Process.send_after(self(), :recompute_scores, 0)
      {:ok, %{interval: interval * 1000}}
    else
      {:ok, %{interval: interval * 1000}}
    end
  end

  @impl true
  def handle_info(:recompute_scores, state) do
    try do
      recompute_all_scores()
    rescue
      e ->
        Logger.error("ScoreScheduler error: #{inspect(e)}")
    end

    # Schedule next run
    Process.send_after(self(), :recompute_scores, state.interval)
    {:noreply, state}
  end

  defp recompute_all_scores do
    # Find all tasks that have signals
    task_ids =
      ItemSignal
      |> select([s], {s.tenant_id, s.item_type, s.item_id})
      |> distinct(true)
      |> Repo.all()

    Logger.debug("ScoreScheduler: recomputing #{length(task_ids)} items")

    Enum.each(task_ids, fn {tenant_id, item_type, item_id} ->
      ScoreEngine.recompute_item(tenant_id, item_type, item_id)
    end)

    # Also ensure all tasks without scores get initialized
    initialize_missing_scores()

    Logger.info("ScoreScheduler: recompute complete (#{length(task_ids)} items)")
  end

  defp initialize_missing_scores do
    # Find tasks that don't have scores yet
    sql = """
    INSERT INTO gtd_item_scores (id, item_type, item_id, tenant_id, why_next_score, why_next_reason, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      'task',
      t.id,
      t.tenant_id,
      CASE
        WHEN t.status = 'active' THEN 10.0
        WHEN t.status = 'inbox' THEN 5.0
        ELSE 0.0
      END,
      'initialized: status=' || t.status,
      now(),
      now()
    FROM tasks t
    LEFT JOIN gtd_item_scores s ON s.item_id = t.id AND s.item_type = 'task' AND s.tenant_id = t.tenant_id
    WHERE s.id IS NULL
      AND t.status IN ('active', 'inbox')
    ON CONFLICT (item_type, item_id, tenant_id) DO NOTHING
    """

    Repo.query!(sql, [])
  end
end

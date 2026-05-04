defmodule BotArmyGtd.IntentEvaluator do
  @moduledoc """
  Evaluates intent decisions during GTD heartbeat cycles.

  Called from PulsePublisher after each pulse tick. Reads accumulated context,
  applies threshold rules, and publishes intents when conditions are met.

  Current intents:
  - `nudge` — suggest user action on stale tasks
  - `remind` — remind about upcoming deadlines or long-idle projects

  Thresholds are configurable via application env:
      config :bot_army_gtd, :intent_thresholds, %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.3},
        random_threshold: 0.5
      }
  """

  use GenServer

  require Logger

  alias BotArmyRuntime.Intent.AccumulatedContext
  alias BotArmyRuntime.Intent.Publisher
  alias BotArmyRuntime.Intent.ThresholdModel

  @bot_name "gtd"
  @evaluate_interval_ms 5 * 60 * 1000

  @default_thresholds %{
    stale_task_count: %{min: 3, weight: 0.6},
    idle_minutes: %{min: 30, weight: 0.3},
    random_threshold: 0.5
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record observations from a pulse tick. Called by PulsePublisher.
  """
  @spec record_observations(map()) :: :ok
  def record_observations(pulse_data) do
    GenServer.cast(__MODULE__, {:record_observations, pulse_data})
  end

  @doc """
  Force an intent evaluation immediately (for testing).
  """
  @spec evaluate_now() :: {:ok, [any()]} | {:error, term()}
  def evaluate_now do
    GenServer.call(__MODULE__, :evaluate_now, 10_000)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.send_after(self(), :evaluate, @evaluate_interval_ms)
    {:ok, %{last_evaluation: nil}}
  end

  @impl true
  def handle_cast({:record_observations, pulse_data}, state) do
    observations = extract_observations(pulse_data)
    Enum.each(observations, &AccumulatedContext.record(@bot_name, &1))
    {:noreply, state}
  end

  @impl true
  def handle_call(:evaluate_now, _from, state) do
    results = do_evaluate()
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    results = do_evaluate()
    Process.send_after(self(), :evaluate, @evaluate_interval_ms)
    {:noreply, %{state | last_evaluation: DateTime.utc_now()}}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp do_evaluate do
    thresholds = get_thresholds()
    context = AccumulatedContext.snapshot(@bot_name)

    evaluate_intent("nudge", thresholds, context) ++
      evaluate_intent("remind", thresholds, context)
  end

  defp evaluate_intent(action, thresholds, context) do
    case ThresholdModel.evaluate(@bot_name, action, thresholds, context) do
      {:ok, :act, details} ->
        Logger.info("[IntentEvaluator] Acting on #{action} intent (score=#{details.score})",
          action: action,
          score: details.score,
          reason: details.reason
        )

        case Publisher.publish_intent(@bot_name, action, %{
               threshold_result: details,
               context_snapshot: %{entry_count: context.entry_count}
             }) do
          {:proceed, intent_id} ->
            Logger.info("[IntentEvaluator] Proceeding with #{action} (intent_id=#{intent_id})")
            [{:acted, action, intent_id, details}]

          {:vetoed, vetoing_bot, reason} ->
            Logger.info("[IntentEvaluator] #{action} vetoed by #{vetoing_bot}: #{reason}")
            [{:vetoed, action, vetoing_bot, reason}]

          {:error, reason} ->
            Logger.warning("[IntentEvaluator] Failed to publish #{action}: #{inspect(reason)}")
            []
        end

      {:ok, :defer, details} ->
        Logger.debug(
          "[IntentEvaluator] Deferring #{action} (score=#{details.score}, reason=#{details.reason})"
        )

        []

      {:ok, :abort, details} ->
        Logger.debug(
          "[IntentEvaluator] Aborting #{action} (score=#{details.score}, reason=#{details.reason})"
        )

        []

      {:error, :disabled} ->
        []

      {:error, reason} ->
        Logger.warning("[IntentEvaluator] Error evaluating #{action}: #{inspect(reason)}")
        []
    end
  end

  @doc false
  def extract_observations(pulse_data) do
    observations = []

    total_tasks =
      get_in(pulse_data, ["observations", "total_active_tasks"]) || 0

    observations =
      if total_tasks > 0 do
        [
          %{
            type: :stale_task_count,
            value: total_tasks,
            observed_at: DateTime.utc_now(),
            metadata: %{source: "pulse"}
          }
          | observations
        ]
      else
        observations
      end

    goals = get_in(pulse_data, ["observations", "goals"]) || %{}

    stale_per_project =
      goals
      |> Enum.map(fn {goal_id, goal_data} ->
        old_count = Map.get(goal_data, "tasks_older_than_7d", 0)
        {goal_id, old_count}
      end)
      |> Enum.filter(fn {_id, count} -> count > 0 end)

    observations =
      Enum.map(stale_per_project, fn {goal_id, count} ->
        %{
          type: :stale_task_count,
          value: count,
          observed_at: DateTime.utc_now(),
          metadata: %{project_id: goal_id}
        }
      end) ++ observations

    observations
  end

  defp get_thresholds do
    Application.get_env(:bot_army_gtd, :intent_thresholds, @default_thresholds)
  end
end

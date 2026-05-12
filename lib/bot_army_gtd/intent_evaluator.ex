defmodule BotArmyGtd.IntentEvaluator do
  @moduledoc """
  Evaluates intent decisions during GTD heartbeat cycles.

  Called from PulsePublisher after each pulse tick. Reads accumulated context,
  applies threshold rules, and publishes intents when conditions are met.

  When an intent is deferred (threshold not met but score is close), starts
  an LLM conversation to compose a softer, context-aware message instead of
  doing nothing. The LLM-composed message is delivered via the notification
  router at "ambient" urgency.

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
  alias BotArmyRuntime.Intent.ActionHandler
  alias BotArmyRuntime.Intent.DeferHandler
  alias BotArmyRuntime.Intent.Publisher
  alias BotArmyRuntime.Intent.ThresholdModel

  @bot_name "gtd"
  @evaluate_interval_ms 5 * 60 * 1000

  @default_thresholds %{
    stale_task_count: %{min: 3, weight: 0.6},
    idle_minutes: %{min: 30, weight: 0.3},
    random_threshold: 0.5,
    overwhelmed_stale_count: %{min: 5, weight: 0.8},
    random_social_threshold: 0.3
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
    {:ok, %{last_evaluation: nil, pending_defers: %{}}}
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
    new_pending = process_defer_results(results, state.pending_defers)
    process_act_results(results)
    Process.send_after(self(), :evaluate, @evaluate_interval_ms)
    {:noreply, %{state | last_evaluation: DateTime.utc_now(), pending_defers: new_pending}}
  end

  @impl true
  def handle_info({:conv_reply, conversation_id, body}, state) do
    case Map.get(state.pending_defers, conversation_id) do
      nil ->
        Logger.debug(
          "[IntentEvaluator] Ignoring conv_reply for unknown conversation #{String.slice(conversation_id, 0..7)}"
        )

        {:noreply, state}

      {action, details, config} ->
        Logger.debug(
          "[IntentEvaluator] Processing #{action} defer reply for #{String.slice(conversation_id, 0..7)}"
        )

        DeferHandler.process_reply(@bot_name, conversation_id, body, details, config)

        {:noreply, %{state | pending_defers: Map.delete(state.pending_defers, conversation_id)}}
    end
  end

  @impl true
  def handle_info({:conv_timeout, conversation_id}, state) do
    if Map.has_key?(state.pending_defers, conversation_id) do
      Logger.debug(
        "[IntentEvaluator] Defer conversation #{String.slice(conversation_id, 0..7)} timed out"
      )

      {:noreply, %{state | pending_defers: Map.delete(state.pending_defers, conversation_id)}}
    else
      {:noreply, state}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp do_evaluate do
    thresholds = get_thresholds()
    context = AccumulatedContext.snapshot(@bot_name)

    evaluate_intent("nudge", thresholds, context) ++
      evaluate_intent("remind", thresholds, context) ++
      evaluate_intent("propose_social_check_in", thresholds, context)
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
          {:proceed, intent_id, endorsements} ->
            endorsers = Enum.map(endorsements, fn {bot, _} -> bot end)

            Logger.info(
              "[IntentEvaluator] Proceeding with #{action} (intent_id=#{intent_id}, endorsed_by=#{inspect(endorsers)})"
            )

            [{:acted, action, intent_id, details, endorsements}]

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

        [{:deferred, action, details, context}]

      {:ok, :abort, details} ->
        Logger.debug(
          "[IntentEvaluator] Aborting #{action} (score=#{details.score}, reason=#{details.reason})"
        )

        publish_aborted_event(@bot_name, action, details)

        []

      {:error, :disabled} ->
        []

      {:error, reason} ->
        Logger.warning("[IntentEvaluator] Error evaluating #{action}: #{inspect(reason)}")
        []
    end
  end

  defp process_defer_results(results, pending_defers) do
    Enum.reduce(results, pending_defers, fn
      {:deferred, action, details, context}, acc ->
        config = defer_config(action)

        if config do
          case DeferHandler.handle_defer(@bot_name, action, details, context, config) do
            {:ok, conversation_id} ->
              Map.put(acc, conversation_id, {action, details, config})

            _ ->
              acc
          end
        else
          acc
        end

      _result, acc ->
        acc
    end)
  end

  defp process_act_results(results) do
    Enum.each(results, fn
      {:acted, action, intent_id, details, endorsements} ->
        config = act_config(action)

        ActionHandler.execute_action(
          @bot_name,
          action,
          intent_id,
          details,
          endorsements,
          config
        )

      _result ->
        :ok
    end)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Act Configuration
  # ───────────────────────────────────────────────────────────────────────────

  defp act_config("nudge") do
    [
      handler_fn: &__MODULE__.handle_nudge_action/5
    ]
  end

  defp act_config("remind") do
    [
      handler_fn: &__MODULE__.handle_remind_action/5
    ]
  end

  defp act_config("propose_social_check_in") do
    [
      handler_fn: &__MODULE__.handle_propose_social_check_in_action/5
    ]
  end

  defp act_config(_), do: nil

  @doc false
  def handle_nudge_action(bot_name, action, _intent_id, details, _endorsements) do
    BotArmyRuntime.NATS.Publisher.publish("notification.route.request", %{
      "event_id" => UUID.uuid4(),
      "triggered_by" => bot_name,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "category" => "task",
      "urgency" => "normal",
      "title" => "#{String.capitalize(action)} suggestion",
      "body" => nudge_body(details)
    })
  end

  @doc false
  def handle_remind_action(bot_name, action, _intent_id, details, _endorsements) do
    BotArmyRuntime.NATS.Publisher.publish("notification.route.request", %{
      "event_id" => UUID.uuid4(),
      "triggered_by" => bot_name,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "category" => "task",
      "urgency" => "high",
      "title" => "#{String.capitalize(action)}: deadline approaching",
      "body" => remind_body(details)
    })
  end

  @doc false
  def handle_propose_social_check_in_action(bot_name, _action, _intent_id, details, _endorsements) do
    stale = Map.get(details, :stale_task_count, Map.get(details, :value, 0))
    score = Map.get(details, :score, 0.5)

    if stale >= 5 do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gossip.social.invite",
        "schema_version" => "1.0",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "bot_army_gtd",
        "tenant_id" => BotArmyRuntime.Tenant.default_tenant_id(),
        "conversation_id" => UUID.uuid4(),
        "payload" => %{
          "from_bot" => bot_name,
          "to_bot" => "fitness_bot",
          "topic" => "overwhelmed_check_in",
          "adaptive_score" => score,
          "cooldown_seconds" => 86_400,
          "stale_task_count" => stale
        }
      }

      BotArmyRuntime.NATS.Publisher.publish("gossip.social.invite", message)
      Logger.info("[GTD.Intent] Proposed social check-in to fitness_bot (stale=#{stale})")
    end
  end

  defp nudge_body(details) do
    count = Map.get(details, :stale_task_count, Map.get(details, :value, 0))

    "You have #{count} stale task#{if count > 1, do: "s", else: ""} that could use attention."
  end

  defp remind_body(details) do
    idle_min = Map.get(details, :idle_minutes, 0)
    hours = div(trunc(idle_min), 60)

    "You've been idle for #{hours} hour#{if hours != 1, do: "s", else: ""} — time to check in on your projects."
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Defer Configuration
  # ───────────────────────────────────────────────────────────────────────────

  defp defer_config("nudge") do
    [
      prompt_builder: &__MODULE__.build_nudge_defer_prompt/3,
      delivery_fn: &__MODULE__.deliver_defer_message/4,
      llm_intent: "classify",
      timeout_ms: 15_000
    ]
  end

  defp defer_config("remind") do
    [
      prompt_builder: &__MODULE__.build_remind_defer_prompt/3,
      delivery_fn: &__MODULE__.deliver_defer_message/4,
      llm_intent: "classify",
      timeout_ms: 15_000
    ]
  end

  defp defer_config(_), do: nil

  @doc false
  def build_nudge_defer_prompt(action, details, context) do
    stale_count = get_in(context, [:summary, :stale_task_count]) || 0

    %{
      "intent" => "classify",
      "text" =>
        "The user has #{stale_count} stale tasks but conditions don't warrant a full #{action} " <>
          "(score #{Float.round(details.score, 2)}, reason: #{details.reason}). " <>
          "Write a one-sentence gentle reminder about their stale tasks. " <>
          "If not useful, respond: skip"
    }
  end

  @doc false
  def build_remind_defer_prompt(action, details, context) do
    idle_minutes = get_in(context, [:summary, :idle_minutes]) || 0

    %{
      "intent" => "classify",
      "text" =>
        "The user has been idle for #{div(trunc(idle_minutes), 60)} hours but " <>
          "conditions don't warrant a full #{action} (score #{Float.round(details.score, 2)}, " <>
          "reason: #{details.reason}). " <>
          "Write a one-sentence soft prompt about their projects. " <>
          "If not useful, respond: skip"
    }
  end

  @doc false
  def deliver_defer_message(bot_name, action, llm_response, details) do
    message =
      case llm_response do
        %{"response" => "skip"} -> nil
        %{"response" => text} when is_binary(text) -> String.trim(text)
        _ -> nil
      end

    if message do
      BotArmyRuntime.NATS.Publisher.publish("notification.route.request", %{
        "event_id" => UUID.uuid4(),
        "triggered_by" => bot_name,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "category" => "task",
        "urgency" => "ambient",
        "title" => "#{String.capitalize(action)} suggestion",
        "body" => message,
        "meta" => %{
          "score" => details.score,
          "reason" => details.reason
        }
      })

      :ok
    else
      :ok
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

    total_stale = Enum.sum(Enum.map(stale_per_project, fn {_id, c} -> c end)) + total_tasks

    observations =
      if total_stale >= 5 do
        [
          %{
            type: :overwhelmed_stale_count,
            value: total_stale,
            observed_at: DateTime.utc_now(),
            metadata: %{source: "pulse", total_stale: total_stale}
          }
          | observations
        ]
      else
        observations
      end

    observations
  end

  defp publish_aborted_event(bot_name, action, details) do
    event = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.bot_army.intent.aborted",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => Atom.to_string(node()),
      "payload" => %{
        "bot_name" => bot_name,
        "action" => action,
        "score" => details.score,
        "reason" => Atom.to_string(details.reason),
        "aborted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    Task.start(fn ->
      BotArmyRuntime.NATS.Publisher.publish("events.bot_army.intent.aborted", event)
    end)
  end

  defp get_thresholds do
    Application.get_env(:bot_army_gtd, :intent_thresholds, @default_thresholds)
  end
end

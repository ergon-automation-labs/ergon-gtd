defmodule BotArmyGtd.Application do
  @moduledoc """
  BotArmyGtd application supervisor.

  Manages GTD bot services:
  - NATS message consumer
  - Event handlers
  - Task processing pipeline
  """

  use Application

  # Derive version from mix.exs at compile time (available in releases via @attrs)
  @version Mix.Project.config()[:version]

  defp env, do: String.to_atom(System.get_env("MIX_ENV") || "prod")

  @impl true
  def start(_type, _args) do
    base_children =
      []
      |> maybe_add_repo()
      |> maybe_add_task_store()
      |> maybe_add_project_store()
      |> maybe_add_plan_store()
      |> maybe_add_inbox_item_store()
      |> maybe_add_decomposition_store()
      |> maybe_add_log_entry_store()
      |> maybe_add_review_scheduler()
      |> maybe_add_army_context_consumer()
      |> maybe_add_pulse_publisher()
      |> maybe_add_intent_evaluator()
      |> maybe_add_veto_listener()

    children =
      base_children ++
        maybe_add_consumer([]) ++
        maybe_add_health_responder([]) ++
        maybe_add_outcome_tracker([])

    opts = [strategy: :one_for_one, name: BotArmyGtd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if env() == :test, do: children, else: [BotArmyGtd.Repo | children]
  end

  defp maybe_add_task_store(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.TaskStore, []} | children]
  end

  defp maybe_add_project_store(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.ProjectStore, []} | children]
  end

  defp maybe_add_plan_store(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.PlanStore, []} | children]
  end

  defp maybe_add_inbox_item_store(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.InboxItemStore, []} | children]
  end

  defp maybe_add_decomposition_store(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.DecompositionStore, []} | children]
  end

  defp maybe_add_log_entry_store(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.LogEntryStore, []} | children]
  end

  defp maybe_add_review_scheduler(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.ReviewScheduler, []} | children]
  end

  defp maybe_add_consumer(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.NATS.Consumer, []} | children]
  end

  defp maybe_add_health_responder(children) do
    if env() == :test,
      do: children,
      else: [
        {BotArmyRuntime.Health.Responder,
         [bot_name: :gtd, repo: BotArmyGtd.Repo, version: @version]}
      ]
  end

  defp maybe_add_army_context_consumer(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.ArmyContextConsumer, []} | children]
  end

  defp maybe_add_pulse_publisher(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.PulsePublisher, []} | children]
  end

  defp maybe_add_intent_evaluator(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.IntentEvaluator, []} | children]
  end

  defp maybe_add_veto_listener(children) do
    if env() == :test do
      children
    else
      veto_rules = [
        [
          bot: "fitness",
          action: "suggest_workout",
          custom: &BotArmyGtd.VetoRules.veto_fitness_suggest_when_stale_tasks/1,
          reason: "user has 5+ stale tasks, focus on clearing backlog first"
        ],
        [
          bot: "chore",
          action: "remind_overdue",
          custom: &BotArmyGtd.VetoRules.veto_chore_remind_when_no_tasks/1,
          reason: "user has no active task context, chore reminder won't land well"
        ]
      ]

      child = {BotArmyRuntime.Intent.VetoListener, rules: veto_rules, bot_name: "gtd"}
      [child | children]
    end
  end

  defp maybe_add_outcome_tracker(children) do
    if env() == :test,
      do: children,
      else: [
        {BotArmyLearning.OutcomeTracker, [name: :gtd_outcome_tracker, repo: BotArmyGtd.Repo]}
        | children
      ]
  end
end

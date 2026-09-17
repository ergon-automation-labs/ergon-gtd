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
    # Load configuration from Salt-deployed config file (not env vars)
    # This fixes macOS launchd environment variable pass-through limitation
    config_data = BotArmyLibraryRuntime.ConfigLoader.load_config()
    Application.put_env(:bot_army_library_runtime, :config_data, config_data)

    base_children =
      []
      |> maybe_add_repo()
      |> maybe_add_leader_monitor()
      |> maybe_add_task_store()
      |> maybe_add_project_store()
      |> maybe_add_plan_store()
      |> maybe_add_inbox_item_store()
      |> maybe_add_decomposition_store()
      |> maybe_add_log_entry_store()
      |> maybe_add_review_scheduler()
      |> maybe_add_score_scheduler()
      |> maybe_add_army_context_consumer()
      |> maybe_add_outcomes_consumer()
      |> maybe_add_weekly_reports_publisher()
      |> maybe_add_anomaly_alerter()
      |> maybe_add_pulse_publisher()
      |> maybe_add_intent_evaluator()
      |> maybe_add_veto_listener()
      # Each maybe_add_* prepends, so the pipeline builds the list back-to-front.
      # Reverse it so children start in the order written above: Repo first.
      |> Enum.reverse()

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

  defp maybe_add_leader_monitor(children) do
    if env() == :test do
      children
    else
      role_str = BotArmyLibraryRuntime.ConfigLoader.get("GTD_NODE_ROLE", "primary")
      default_role = parse_role(role_str)

      [
        {BotArmyLibraryRuntime.LeaderElection,
         service: "gtd",
         node_name: BotArmyLibraryRuntime.ConfigLoader.get("NODE_NAME", "unknown"),
         default_role: default_role,
         on_role_change: {BotArmyGtd.LeaderMonitor, :role_changed, []}}
        | children
      ]
    end
  end

  defp parse_role("standby"), do: :standby
  defp parse_role("primary"), do: :primary
  defp parse_role(_), do: :primary

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

  defp maybe_add_score_scheduler(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.ScoreScheduler, []} | children]
  end

  defp maybe_add_consumer(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.NATS.Consumer, []} | children]
  end

  defp maybe_add_health_responder(children) do
    if env() == :test or Application.get_env(:bot_army_library_runtime, :pack_mode, false),
      do: children,
      else: [
        {BotArmyLibraryRuntime.Health.Responder,
         [bot_name: :gtd, repo: BotArmyGtd.Repo, version: @version]}
      ]
  end

  defp maybe_add_army_context_consumer(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.ArmyContextConsumer, []} | children]
  end

  defp maybe_add_outcomes_consumer(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.NATS.OutcomesConsumer, []} | children]
  end

  defp maybe_add_weekly_reports_publisher(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyGtd.NATS.WeeklyReportsPublisher, []} | children]
  end

  defp maybe_add_anomaly_alerter(children) do
    if env() == :test, do: children, else: [{BotArmyGtd.NATS.AnomalyAlerter, []} | children]
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

      child = {BotArmyLibraryRuntime.Intent.VetoListener, rules: veto_rules, bot_name: "gtd"}
      [child | children]
    end
  end

  @doc false
  # Exposed for tests. The test environment skips this child (see
  # maybe_add_outcome_tracker/1), which is exactly why a wrong registration
  # name survived review and only surfaced in a Docker fleet boot.
  def outcome_tracker_spec do
    # P10 (2026-09-06, Docker fleet test): IntentEvaluator →
    # ThresholdAdapter.adjustment → library OutcomeTracker.stats/1 calls the
    # tracker under its DEFAULT (module) name; registering ours as
    # :gtd_outcome_tracker left that call dead ("no process") and crashed the
    # IntentEvaluator. One bot per BEAM in Docker — honor the library's
    # default-name contract.
    #
    # 2026-09-16: passing :repo alone does NOT satisfy that contract.
    # start_link/1 checks opts[:name] first and otherwise DERIVES
    # :"#{repo}_outcome_tracker" from opts[:repo], so dropping the explicit
    # name merely swapped one wrong registration for another
    # (:"Elixir.BotArmyGtd.Repo_outcome_tracker") and the 5-minute
    # IntentEvaluator crash continued in prod (v0.7.230, which registered
    # :gtd_outcome_tracker) and on main. :name must be explicit; :repo is still
    # required so outcomes persist to gtd's database.
    {BotArmyLibraryLearning.OutcomeTracker,
     [name: BotArmyLibraryLearning.OutcomeTracker, repo: BotArmyGtd.Repo]}
  end

  defp maybe_add_outcome_tracker(children) do
    if env() == :test,
      do: children,
      else: [outcome_tracker_spec() | children]
  end

end

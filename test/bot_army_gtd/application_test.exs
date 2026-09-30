defmodule BotArmyGtd.ApplicationTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLibraryLearning.OutcomeTracker
  alias BotArmyLibraryLearning.ThresholdAdapter

  # BotArmyGtd.IntentEvaluator runs every 5 minutes and asks ThresholdAdapter for an
  # accuracy adjustment (the nudge path). ThresholdAdapter -> OutcomeTracker.stats/1
  # addresses the tracker as the library's @default_name (the module atom), so the
  # child spec must register exactly that name. Two variants shipped, and both
  # crashed the evaluator on every cycle:
  #
  #   v0.7.230 (prod)  [name: :gtd_outcome_tracker, repo: ...]  -> call dead
  #   main (0.7.231)   [repo: ...]  -> start_link derives :"...Repo_outcome_tracker"
  #
  # This test starts the spec itself rather than relying on the application tree.
  # It used to rely on it, because env/0 read the OS MIX_ENV variable, which is
  # stale ("dev") inside the test VM -- so the production tree, Repo against a real
  # database and the live-subscribing NATS consumer included, booted during
  # `mix test`. env/0 now reads application config (config/test.exs sets :test).
  test "the tracker registers under the name its callers use, so the nudge path works" do
    assert {OutcomeTracker, opts} = BotArmyGtd.Application.outcome_tracker_spec()
    assert Keyword.fetch!(opts, :name) == OutcomeTracker

    start_supervised!({OutcomeTracker, opts})

    assert Process.whereis(OutcomeTracker), "no tracker is registered under the callers' name"

    # The exact production call path: IntentEvaluator.do_evaluate/0 -> get_thresholds/0.
    assert is_number(ThresholdAdapter.adjustment("gtd.nudge"))
  end

  # Positive control for the trap above: `:repo` alone used to derive a different
  # registered name (:"...Repo_outcome_tracker"), which left default-name callers dead.
  # bot_army_library_learning >= 0.1.45 closed that: `:repo` never affects the name.
  # This asserts the closure, so it fails if the trap ever comes back.
  test "passing :repo without :name still targets the callers' name (trap closed)" do
    derived = :"#{BotArmyGtd.Repo}_outcome_tracker"
    assert Process.whereis(derived) == nil, "the derived trap name is registered again"

    # Start a tracker with :repo only, so the next start collides with it. No :name
    # given, so this must land under the callers' name -- proof that :repo did not
    # move the registration anywhere.
    start_supervised!({OutcomeTracker, [repo: BotArmyGtd.Repo]})
    assert Process.whereis(OutcomeTracker)

    assert {:error, {:already_started, pid}} = OutcomeTracker.start_link(repo: BotArmyGtd.Repo)
    assert pid == Process.whereis(OutcomeTracker)
  end

  # Regression guard for the environment landmine described above: if env/0 ever
  # reads the OS variable again, the whole production tree returns to every test
  # run (real database, ~46 live NATS subscriptions) and these fail.
  test "env/0 reads application config, not the stale OS MIX_ENV variable" do
    assert Application.get_env(:bot_army_gtd, :env) == :test
    assert BotArmyGtd.Application.env() == :test
  end

  test "the production children do not boot under test" do
    refute Process.whereis(BotArmyGtd.Repo),
           "BotArmyGtd.Repo booted in tests: every test run would hit a real database"

    refute Process.whereis(BotArmyGtd.TaskStore), "BotArmyGtd.TaskStore booted in tests"

    refute Process.whereis(BotArmyGtd.NATS.Consumer),
           "the NATS consumer booted in tests: it would subscribe to the live broker"
  end
end

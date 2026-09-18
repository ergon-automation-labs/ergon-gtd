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
  # env/0 defaults to :prod when MIX_ENV is unset, so the app tree (and this
  # tracker) really does start during `mix test` — which is what lets this test
  # observe the registration.
  test "the tracker registers under the name its callers use, so the nudge path works" do
    assert {OutcomeTracker, opts} = BotArmyGtd.Application.outcome_tracker_spec()
    assert Keyword.fetch!(opts, :name) == OutcomeTracker

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

    # No :name given, so this must collide with the tracker the app already runs under
    # the callers' name -- proof that :repo did not move the registration anywhere.
    assert {:error, {:already_started, pid}} = OutcomeTracker.start_link(repo: BotArmyGtd.Repo)
    assert pid == Process.whereis(OutcomeTracker)
  end
end

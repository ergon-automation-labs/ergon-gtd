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

  # Positive control for the trap above: with :repo but no :name the library derives a
  # different name, which is what left the default-name call dead. If this test ever
  # fails, the library changed and the trap no longer exists.
  test "passing :repo without :name registers a DIFFERENT name (the trap)" do
    start_supervised!({OutcomeTracker, [repo: BotArmyGtd.Repo]})
    derived = :"#{BotArmyGtd.Repo}_outcome_tracker"

    assert Process.whereis(derived), "the derived name is what actually gets registered"
    assert Process.whereis(derived) != Process.whereis(OutcomeTracker)
  end
end

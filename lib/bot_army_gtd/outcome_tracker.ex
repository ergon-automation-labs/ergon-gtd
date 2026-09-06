defmodule BotArmyGtd.OutcomeTracker do
  @moduledoc """
  Delegates to BotArmyLibraryLearning.OutcomeTracker.

  P10 (2026-09-06, Docker fleet test): previously targeted a custom
  :gtd_outcome_tracker registration while the library's ThresholdAdapter
  (used by IntentEvaluator) calls the DEFAULT module-name server — the
  mismatch crashed IntentEvaluator. Both paths now target the module name.
  """

  def record(id, category, decision, actual_result) do
    GenServer.cast(BotArmyLibraryLearning.OutcomeTracker, {:record, id, category, decision, actual_result})
  end

  def stats(category) do
    GenServer.call(BotArmyLibraryLearning.OutcomeTracker, {:stats, category})
  end

  def recent(category, count) do
    GenServer.call(BotArmyLibraryLearning.OutcomeTracker, {:recent, category, count})
  end

  def recent_by_sub_key(category, sub_key, count) do
    GenServer.call(BotArmyLibraryLearning.OutcomeTracker, {:recent_by_sub_key, category, sub_key, count})
  end
end

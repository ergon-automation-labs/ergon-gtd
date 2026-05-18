defmodule BotArmyGtd.OutcomeTracker do
  @moduledoc """
  Delegates to BotArmyLearning.OutcomeTracker with GTD-specific name.
  """

  def record(id, category, decision, actual_result) do
    GenServer.cast(:gtd_outcome_tracker, {:record, id, category, decision, actual_result})
  end

  def stats(category) do
    GenServer.call(:gtd_outcome_tracker, {:stats, category})
  end

  def recent(category, count) do
    GenServer.call(:gtd_outcome_tracker, {:recent, category, count})
  end

  def recent_by_sub_key(category, sub_key, count) do
    GenServer.call(:gtd_outcome_tracker, {:recent_by_sub_key, category, sub_key, count})
  end
end

defmodule BotArmyGtd.VetoRules do
  @moduledoc false

  alias BotArmyLibraryRuntime.Intent.AccumulatedContext

  @doc """
  Veto fitness suggest_workout intents when the user has many stale tasks.
  If there are 5+ stale tasks, fitness suggestions are counterproductive —
  the user should focus on clearing their task backlog first.
  """
  @spec veto_fitness_suggest_when_stale_tasks(map()) :: boolean()
  def veto_fitness_suggest_when_stale_tasks(_envelope) do
    case AccumulatedContext.latest("gtd", :stale_task_count) do
      nil -> false
      entry -> entry.value >= 5
    end
  end

  @doc """
  Veto chore remind_overdue intents when there are no active GTD tasks.
  If the user has no task context at all, chore reminders won't land well.
  """
  @spec veto_chore_remind_when_no_tasks(map()) :: boolean()
  def veto_chore_remind_when_no_tasks(_envelope) do
    case AccumulatedContext.snapshot("gtd") do
      %{entry_count: count} when count > 0 -> false
      _ -> true
    end
  end
end

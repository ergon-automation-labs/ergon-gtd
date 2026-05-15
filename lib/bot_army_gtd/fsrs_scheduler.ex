defmodule BotArmyGtd.FSRSScheduler do
  @moduledoc """
  FSRS (Free Spaced Repetition Scheduler) implementation for GTD decompositions.

  Calculates optimal review timing based on stability and difficulty parameters.

  The FSRS algorithm adapts review intervals based on:
  1. Stability - how long memory remains without decay
  2. Difficulty - resistance to forgetting
  3. User grade - feedback on whether the user got it right (1-4)

  Grades:
  - 1 (Again): User failed, reschedule immediately
  - 2 (Hard): User struggled, reduce interval slightly
  - 3 (Good): Normal difficulty, extend interval
  - 4 (Easy): User found it easy, extend interval more

  Reference: https://github.com/open-spaced-repetition/free-spaced-repetition-scheduler
  """

  require Logger

  # Start with 1 day interval
  @initial_stability 1.0
  # Medium difficulty (0-10 scale)
  @initial_difficulty 5.0

  @doc """
  Calculate next review interval in days for a decomposition.

  Based on current stability and a user grade (1-4).
  Returns {new_stability, new_difficulty, new_due_at}

  Handles both map-style (database) and struct-style decompositions.
  """
  def schedule_next_review(decomposition, grade) when grade in [1, 2, 3, 4] do
    # Handle both map and struct-style access
    current_stability = get_field(decomposition, :stability) || @initial_stability
    current_difficulty = get_field(decomposition, :difficulty) || @initial_difficulty

    new_stability = calculate_new_stability(current_stability, current_difficulty, grade)
    new_difficulty = calculate_new_difficulty(current_difficulty, grade)
    new_due_at = calculate_next_due_at(new_stability)

    {new_stability, new_difficulty, new_due_at}
  end

  def schedule_next_review(_decomposition, _grade) do
    {:error, :invalid_grade}
  end

  # Helper to safely access fields from maps or structs
  defp get_field(decomposition, field) when is_map(decomposition) do
    Map.get(decomposition, field) || Map.get(decomposition, Atom.to_string(field))
  end

  defp get_field(decomposition, field) do
    Map.fetch!(decomposition, field)
  rescue
    _ -> nil
  end

  @doc """
  Calculate initial schedule for a new decomposition.
  Start with 1 day interval.
  """
  def initial_schedule do
    {
      @initial_stability,
      @initial_difficulty,
      DateTime.add(DateTime.utc_now(), 1, :day)
    }
  end

  @doc """
  Get decompositions due for review.

  Returns all decompositions where due_at <= now
  """
  def get_due_for_review(decompositions) do
    now = DateTime.utc_now()

    decompositions
    |> Enum.filter(fn d ->
      d.status == "completed" and d.due_at and DateTime.compare(d.due_at, now) in [:lt, :eq]
    end)
    |> Enum.sort_by(& &1.due_at)
  end

  @doc """
  Get upcoming decompositions (next 7 days).
  """
  def get_upcoming(decompositions) do
    now = DateTime.utc_now()
    week_from_now = DateTime.add(now, 7, :day)

    decompositions
    |> Enum.filter(fn d ->
      d.status == "completed" and d.due_at and
        DateTime.compare(d.due_at, now) in [:gt, :eq] and
        DateTime.compare(d.due_at, week_from_now) in [:lt, :eq]
    end)
    |> Enum.sort_by(& &1.due_at)
  end

  @doc """
  Calculate retention (probability of recall) based on elapsed time since review.

  Uses exponential decay: R(t) = e^(-t/S)
  where t is time since review and S is stability
  """
  def calculate_retention(decomposition) do
    due_at = get_field(decomposition, :due_at)

    case due_at do
      nil ->
        # Not yet scheduled
        1.0

      due_at ->
        now = DateTime.utc_now()
        stability = get_field(decomposition, :stability) || @initial_stability
        stability = max(stability, 0.1)

        # Time since due_at in days
        seconds_elapsed = DateTime.diff(now, due_at)
        days_elapsed = max(0, seconds_elapsed / 86_400)

        # Exponential decay: R(t) = e^(-t/S)
        :math.exp(-days_elapsed / stability)
    end
  end

  @doc """
  Format review interval for display (e.g., "3 days", "2 weeks").
  """
  def format_interval(due_at) when is_nil(due_at) do
    "Not scheduled"
  end

  def format_interval(due_at) do
    now = DateTime.utc_now()

    case DateTime.compare(now, due_at) do
      :lt ->
        seconds_until = DateTime.diff(due_at, now)
        days_until = div(seconds_until, 86_400)
        format_days(days_until)

      :eq ->
        "Due now"

      :gt ->
        seconds_since = DateTime.diff(now, due_at)
        days_since = div(seconds_since, 86_400)
        "Overdue by #{format_days(days_since)}"
    end
  end

  # Private functions

  defp calculate_new_stability(stability, difficulty, grade) do
    # FSRS v11 SM-2 inspired formula (simplified)
    # https://github.com/open-spaced-repetition/free-spaced-repetition-scheduler

    # Base interval multiplier per grade
    multiplier =
      case grade do
        # Again: reduce by half
        1 -> 0.5
        # Hard: reduce to 70%
        2 -> 0.7
        # Good: maintain
        3 -> 1.0
        # Easy: increase by 20%
        4 -> 1.2
      end

    # Difficulty factor (harder items have shorter stability growth)
    difficulty_factor = (5 - difficulty) / 5

    new_stability = stability * multiplier * (0.8 + difficulty_factor * 0.2)
    # Ensure minimum stability
    max(new_stability, 0.1)
  end

  defp calculate_new_difficulty(difficulty, grade) do
    # Adjust difficulty based on performance
    adjustment =
      case grade do
        # Again: increase difficulty
        1 -> 1.0
        # Hard: slight increase
        2 -> 0.3
        # Good: no change
        3 -> 0.0
        # Easy: decrease difficulty
        4 -> -1.0
      end

    new_difficulty = difficulty + adjustment
    # Keep difficulty in reasonable range (0-10)
    max(0.1, min(new_difficulty, 10.0))
  end

  defp calculate_next_due_at(stability) do
    # Next review interval in days, rounded to integer
    days = max(1, round(stability))
    DateTime.add(DateTime.utc_now(), days, :day)
  end

  defp format_days(days) when days == 0, do: "today"
  defp format_days(days) when days == 1, do: "1 day"
  defp format_days(days) when days < 7, do: "#{days} days"
  defp format_days(days) when days < 30, do: "#{div(days, 7)} weeks"
  defp format_days(days), do: "#{div(days, 30)} months"
end

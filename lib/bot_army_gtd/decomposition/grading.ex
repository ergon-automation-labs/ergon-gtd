defmodule BotArmyGtd.Decomposition.Grading do
  @moduledoc """
  Handles the grading and accuracy analysis of task decompositions.
  This module is pure and does not interact with the database.
  """

  @doc """
  Calculate the accuracy delta between predicted and actual values.
  """
  def calculate_accuracy_delta(predicted, actual) when is_number(predicted) and is_number(actual) do
    if predicted == 0, do: 0.0, else: abs(predicted - actual) / predicted
  end

  def calculate_accuracy_delta(_, _), do: 0.0

  @doc """
  Determine the FSRS grade based on user rating and accuracy delta.
  """
  def calculate_fsrs_grade(rating, delta) when is_integer(rating) and is_number(delta) do
    cond do
      rating < 3 or delta > 0.3 -> 0
      rating == 3 and delta > 0.2 -> 1
      rating == 4 and delta < 0.2 -> 2
      rating == 5 and delta < 0.1 -> 3
      true -> 2
    end
  end

  def calculate_fsrs_grade(_, _), do: 2

  @doc """
  Calculate an approval grade based on predicted vs actual subtask count.
  """
  def calculate_approval_grade(predicted, actual, combined_delta \\ 0.0) do
    if is_nil(predicted) or is_nil(actual) do
      3
    else
      diff = abs(predicted - actual)

      cond do
        combined_delta > 0.5 or diff >= 4 -> 1
        combined_delta > 0.2 or diff >= 2 -> 2
        diff == 0 or diff == 1 -> 3
        true -> 2
      end
    end
  end

  @doc """
  Combines count and effort accuracy into a single grade for a decomposition.
  """
  def grade_decomposition_accuracy(predicted_count, actual_count, predicted_hours, actual_hours) do
    count_delta = calculate_accuracy_delta(predicted_count, actual_count)
    effort_delta = calculate_accuracy_delta(predicted_hours, actual_hours)
    combined_delta = max(count_delta, effort_delta)

    {calculate_approval_grade(predicted_count, actual_count, combined_delta), combined_delta}
  end
end

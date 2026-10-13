defmodule BotArmyGtd.IntentEvaluatorReasonTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.IntentEvaluator

  # Regression guard for the intent-evaluator crash loop measured 2026-10-13.
  #
  # `Intent.ThresholdModel` hands back `{:random_error, reason}` as the decision
  # reason when a random roll fails, but the evaluator formatted the reason with
  # `Atom.to_string/1`. On that tuple it raised
  # `ArgumentError: atom_to_binary({:random_error, :timeout})`, and the crash
  # repeated roughly every 1.5-2 hours. The prompt builders interpolate the reason,
  # so they are the observable seam: a tuple must render, not raise.
  describe "non-atom decision reasons" do
    test "build_nudge_defer_prompt tolerates a tuple reason" do
      details = %{score: 0.4, reason: {:random_error, :timeout}}

      prompt = IntentEvaluator.build_nudge_defer_prompt("nudge", details, %{})

      assert prompt["text"] =~ ":random_error"
    end

    test "build_remind_defer_prompt tolerates a tuple reason" do
      details = %{score: 0.2, reason: {:random_error, :timeout}}

      prompt = IntentEvaluator.build_remind_defer_prompt("remind", details, %{})

      assert prompt["text"] =~ ":random_error"
    end

    test "an atom reason still renders as its name" do
      details = %{score: 0.9, reason: :ok}

      prompt = IntentEvaluator.build_nudge_defer_prompt("nudge", details, %{})

      assert prompt["text"] =~ "reason: ok"
      refute prompt["text"] =~ ":ok"
    end
  end
end

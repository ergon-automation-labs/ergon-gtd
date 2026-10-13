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

  # Regression guard for the same crash-loop family, second shape (2026-10-13).
  #
  # `context.summary.<type>` is an aggregate — `%{count:, values:, latest: %{value:, ...}}`
  # (AccumulatedContext.compute_summary/1) — never a scalar. The tests above pass `%{}`,
  # which hid it: `trunc/1` on the aggregate raised ArgumentError and killed fitness's
  # evaluator 232 times on air, and the nudge prompt interpolated the whole map.
  describe "summary aggregates in the defer prompts" do
    test "build_remind_defer_prompt reads hours out of the aggregate" do
      context = %{
        summary: %{
          idle_minutes: %{
            count: 1,
            values: [60],
            latest: %{type: :idle_minutes, value: 60, metadata: %{source: "pulse"}}
          }
        }
      }

      prompt =
        IntentEvaluator.build_remind_defer_prompt(
          "remind",
          %{score: 0.3, reason: :low_roll},
          context
        )

      assert prompt["text"] =~ "idle for 1 hours"
    end

    test "build_nudge_defer_prompt renders the newest count, not the whole map" do
      context = %{
        summary: %{
          stale_task_count: %{
            count: 2,
            values: [5, 7],
            latest: %{type: :stale_task_count, value: 7, metadata: %{source: "pulse"}}
          }
        }
      }

      prompt =
        IntentEvaluator.build_nudge_defer_prompt(
          "nudge",
          %{score: 0.3, reason: :low_roll},
          context
        )

      assert prompt["text"] =~ "has 7 stale tasks"
      refute prompt["text"] =~ "count:"
    end

    test "a scalar summary and a missing type both still work" do
      scalar =
        IntentEvaluator.build_nudge_defer_prompt(
          "nudge",
          %{score: 0.3, reason: :low_roll},
          %{summary: %{stale_task_count: 4}}
        )

      assert scalar["text"] =~ "has 4 stale tasks"

      missing =
        IntentEvaluator.build_remind_defer_prompt(
          "remind",
          %{score: 0.3, reason: :low_roll},
          %{summary: %{}}
        )

      assert missing["text"] =~ "idle for 0 hours"
    end
  end
end

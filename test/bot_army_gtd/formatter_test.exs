defmodule BotArmyGtd.FormatterTest do
  use ExUnit.Case
  @moduletag :format
  doctest BotArmyGtd.Formatter

  alias BotArmyGtd.Formatter

  describe "format/2" do
    test "inbox_cleared with all values" do
      result =
        Formatter.format(:inbox_cleared, %{
          "added" => 3,
          "scheduled" => 2,
          "deleted" => 1
        })

      assert result ==
               "◉ Inbox cleared. 3 tasks added, 2 scheduled, 1 deleted because honestly, no."
    end

    test "inbox_pending with multiple tasks" do
      result = Formatter.format(:inbox_pending, %{"count" => 14})
      assert result == "◉ 14 uncaptured tasks. I'm not saying anything. I'm just saying 14."
    end

    test "inbox_pending with one task" do
      result = Formatter.format(:inbox_pending, %{"count" => 1})
      assert result == "◉ 1 uncaptured tasks. I'm not saying anything. I'm just saying 1."
    end

    test "inbox_pending with zero tasks" do
      result = Formatter.format(:inbox_pending, %{"count" => 0})
      assert result == "◉ Inbox is clear. Well done."
    end

    test "weekly_review_overdue with multiple days" do
      result = Formatter.format(:weekly_review_overdue, %{"days_overdue" => 6})

      assert result ==
               "◉ Weekly review pending for 6 days. When you're ready, I'm ready. I'll be here."
    end

    test "weekly_review_overdue with one day" do
      result = Formatter.format(:weekly_review_overdue, %{"days_overdue" => 1})

      assert result ==
               "◉ Weekly review pending for 1 day. When you're ready, I'm ready. I'll be here."
    end

    test "weekly_review_due" do
      result = Formatter.format(:weekly_review_due, %{})
      assert result == "◉ Weekly review due tomorrow. Block 30 minutes if you can."
    end

    test "task_created with context" do
      result =
        Formatter.format(:task_created, %{
          "title" => "Review Q1 goals",
          "context" => "planning"
        })

      assert result == "◉ Added: Review Q1 goals (planning)"
    end

    test "task_created without context" do
      result = Formatter.format(:task_created, %{"title" => "Review Q1 goals"})
      assert result == "◉ Added: Review Q1 goals"
    end

    test "task_completed" do
      result = Formatter.format(:task_completed, %{"title" => "Send report"})
      assert result == "◉ Done: Send report. Good work."
    end

    test "project_created" do
      result = Formatter.format(:project_created, %{"title" => "Quarterly Planning"})
      assert result == "◉ New project: Quarterly Planning"
    end

    test "decomposition_started" do
      result = Formatter.format(:decomposition_started, %{"task_title" => "Plan vacation"})
      assert result == "◉ Breaking down: Plan vacation"
    end

    test "decomposition_complete" do
      result =
        Formatter.format(:decomposition_complete, %{
          "task_title" => "Plan vacation",
          "subtask_count" => 5
        })

      assert result == "◉ Plan vacation is now 5 concrete next steps. Much better."
    end

    test "error" do
      result = Formatter.format(:error, %{"message" => "Database connection failed"})
      assert result == "◉ Something went wrong: Database connection failed"
    end

    test "unknown type returns default message with symbol" do
      result = Formatter.format(:unknown_type, %{})
      assert result == "◉ Something happened."
    end

    test "all formatted messages include the symbol" do
      messages = [
        Formatter.format(:inbox_cleared, %{"added" => 1, "scheduled" => 1, "deleted" => 1}),
        Formatter.format(:inbox_pending, %{"count" => 5}),
        Formatter.format(:task_created, %{"title" => "Test"}),
        Formatter.format(:task_completed, %{"title" => "Test"}),
        Formatter.format(:project_created, %{"title" => "Test"}),
        Formatter.format(:error, %{"message" => "Test"})
      ]

      Enum.each(messages, fn msg ->
        assert String.starts_with?(msg, "◉ ")
      end)
    end
  end
end

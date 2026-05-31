defmodule BotArmyGtd.DecompositionWithReflectionTest do
  @moduledoc """
  Integration test: Decomposition + Reflection + Orchestration + Learning
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias BotArmyGtd.ReflectionEvaluator

  describe "reflection_evaluator" do
    test "scores high-quality decomposition (5/5)" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Research company funding",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "funding rounds"},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Create task summary",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{"title" => "Funding research summary"},
          "depends_on" => [1]
        }
      ]

      {:ok, score, notes} =
        ReflectionEvaluator.evaluate_decomposition(subtasks, "research company funding")

      assert score >= 4
      assert String.contains?(notes, "excellent")
      assert String.contains?(notes, "research company funding")
    end

    test "detects over-scoped subtasks (low atomicity)" do
      subtasks = [
        %{
          "order" => 1,
          "description" =>
            "Research the company, interview team members, create presentation, send to stakeholders and then gather feedback for analysis",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "company data"},
          "depends_on" => []
        }
      ]

      {:ok, score, notes} = ReflectionEvaluator.evaluate_decomposition(subtasks, "large task")

      assert score < 4
      assert String.contains?(notes, "over-scoped")
    end

    test "detects dependency errors (forward references)" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task 1",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "test"},
          # Forward reference - depends on task 2
          "depends_on" => [2]
        },
        %{
          "order" => 2,
          "description" => "Task 2",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{"title" => "task"},
          "depends_on" => []
        }
      ]

      {:ok, score, notes} = ReflectionEvaluator.evaluate_decomposition(subtasks, "bad deps")

      assert score < 4
      assert String.contains?(notes, "Dependency graph")
    end

    test "detects missing prerequisites" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Query LLM",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          # Missing query or prompt
          "payload" => %{},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Create task",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          # Missing title
          "payload" => %{},
          "depends_on" => [1]
        }
      ]

      {:ok, score, notes} =
        ReflectionEvaluator.evaluate_decomposition(subtasks, "missing prerequisites")

      assert score < 4
      assert String.contains?(notes, "missing prerequisites")
    end

    test "includes goal in reflection notes" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Do something",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "test"},
          "depends_on" => []
        }
      ]

      goal = "hire senior engineer for platform team"

      {:ok, _score, notes} = ReflectionEvaluator.evaluate_decomposition(subtasks, goal)

      assert String.contains?(notes, "hire senior engineer")
    end

    test "scores decomposition with mixed issues" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Research and analyze and summarize company data",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          # Missing query
          "payload" => %{},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Create summary",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{"title" => "summary"},
          "depends_on" => [1]
        }
      ]

      {:ok, score, notes} = ReflectionEvaluator.evaluate_decomposition(subtasks, "complex task")

      # Score should be low due to multiple issues
      assert score <= 3
      assert String.contains?(notes, "Issues found")
    end
  end
end

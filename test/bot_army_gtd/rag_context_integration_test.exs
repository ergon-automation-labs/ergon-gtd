defmodule BotArmyGtd.RagContextIntegrationTest do
  @moduledoc """
  Integration test: RAG context enrichment for decomposition patterns
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias BotArmyGtd.ReflectionEvaluator

  describe "rag_context_enrichment" do
    test "decomposition with resource references scores higher on completeness" do
      # Subtasks WITHOUT context references
      subtasks_no_context = [
        %{
          "order" => 1,
          "description" => "Research hiring process",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "hiring steps"},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Create job posting",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{"title" => "draft job posting"},
          "depends_on" => [1]
        }
      ]

      # Same subtasks but WITH context references
      subtasks_with_context = [
        %{
          "order" => 1,
          "description" => "Research hiring process (see docs/hiring-guide.md)",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "hiring steps"},
          "depends_on" => [],
          "context" => %{
            "docs" => [
              %{"title" => "Hiring Guide", "path" => "docs/hiring-guide.md"}
            ]
          }
        },
        %{
          "order" => 2,
          "description" => "Create job posting (template in docs/templates/job-posting.md)",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{"title" => "draft job posting"},
          "depends_on" => [1]
        }
      ]

      {:ok, score_no_context, _} =
        ReflectionEvaluator.evaluate_decomposition(subtasks_no_context, "hire engineer")

      {:ok, score_with_context, _} =
        ReflectionEvaluator.evaluate_decomposition(subtasks_with_context, "hire engineer")

      # Decomposition with context references should score same or higher
      assert score_with_context >= score_no_context,
             "Context-enriched decomposition should score >= non-enriched version"
    end

    test "completeness bonus for referencing runbooks and guides" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Follow runbook for DB migration",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{"query" => "db migration steps"},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Check guide: safe deployment practices",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{"title" => "verify deployment"},
          "depends_on" => [1]
        }
      ]

      {:ok, score, notes} =
        ReflectionEvaluator.evaluate_decomposition(subtasks, "deploy to production")

      # Score should be good (both subtasks reference resources)
      assert score >= 4,
             "Decomposition with resource references should score well. Got: #{score}. Notes: #{notes}"
    end

    test "decomposition without resource references scores lower when vague" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "TBD: something with research",
          "target_bot" => "bot_army_llm",
          "target_subject" => "llm.query",
          "payload" => %{},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "TODO: implement",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{},
          "depends_on" => [1]
        }
      ]

      {:ok, score, notes} =
        ReflectionEvaluator.evaluate_decomposition(subtasks, "vague task")

      # Score should be low (missing payloads + TBD/TODO markers)
      assert score <= 3,
             "Vague decomposition without resources should score <= 3. Got: #{score}. Notes: #{notes}"
    end
  end
end

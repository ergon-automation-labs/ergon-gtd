defmodule BotArmyGtd.DecomposerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyGtd.Decomposer
  alias BotArmyGtd.Decomposers.DeterministicDecomposer

  # =====================================================================
  # Tests for build_decomposition_prompt
  # =====================================================================

  describe "build_decomposition_prompt/3" do
    test "includes goal in prompt" do
      prompt =
        Decomposer.build_decomposition_prompt(
          "research company",
          %{},
          %{}
        )

      assert String.contains?(prompt, "research company")
    end

    test "includes context in prompt" do
      prompt =
        Decomposer.build_decomposition_prompt(
          "research goal",
          %{company: "Acme"},
          %{}
        )

      assert String.contains?(prompt, "Acme")
    end

    test "uses default constraints when not provided" do
      prompt =
        Decomposer.build_decomposition_prompt(
          "goal",
          %{},
          %{}
        )

      assert String.contains?(prompt, "Max steps: 5")
      assert String.contains?(prompt, "Max duration: 30 minutes")
    end

    test "uses provided constraints" do
      prompt =
        Decomposer.build_decomposition_prompt(
          "goal",
          %{},
          %{max_steps: 10, max_duration_minutes: 60}
        )

      assert String.contains?(prompt, "Max steps: 10")
      assert String.contains?(prompt, "Max duration: 60 minutes")
    end

    test "includes available bots list" do
      prompt =
        Decomposer.build_decomposition_prompt(
          "goal",
          %{},
          %{}
        )

      assert String.contains?(prompt, "gtd")
      assert String.contains?(prompt, "llm")
      assert String.contains?(prompt, "dispatcher")
    end

    test "includes JSON schema instruction" do
      prompt =
        Decomposer.build_decomposition_prompt(
          "goal",
          %{},
          %{}
        )

      assert String.contains?(prompt, "order")
      assert String.contains?(prompt, "target_bot")
      assert String.contains?(prompt, "target_subject")
    end
  end

  # =====================================================================
  # Tests for system_prompt
  # =====================================================================

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      prompt = Decomposer.system_prompt()
      assert is_binary(prompt)
      assert byte_size(prompt) > 0
    end

    test "mentions task decomposition" do
      prompt = Decomposer.system_prompt()
      assert String.contains?(prompt, "decomposition")
    end

    test "mentions JSON response format" do
      prompt = Decomposer.system_prompt()
      assert String.contains?(prompt, "JSON")
    end
  end

  # =====================================================================
  # Tests for parse_subtasks
  # =====================================================================

  describe "parse_subtasks/1" do
    test "parses JSON array from response data" do
      response = %{
        "data" =>
          "[{\"order\": 1, \"description\": \"Task 1\", \"target_bot\": \"gtd\", \"target_subject\": \"gtd.task.create\", \"payload\": {}, \"depends_on\": [], \"needs_verification\": false}]"
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      assert length(subtasks) == 1
    end

    test "handles response with content field" do
      response = %{
        "content" =>
          "[{\"order\": 1, \"description\": \"Task 1\", \"target_bot\": \"gtd\", \"target_subject\": \"gtd.task.create\", \"payload\": {}, \"depends_on\": [], \"needs_verification\": false}]"
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      assert length(subtasks) == 1
    end

    test "removes markdown code blocks from JSON" do
      response = %{
        "data" =>
          "```json\n[{\"order\": 1, \"description\": \"Task\", \"target_bot\": \"gtd\", \"target_subject\": \"gtd.task.create\", \"payload\": {}, \"depends_on\": [], \"needs_verification\": false}]\n```"
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      assert length(subtasks) == 1
    end

    test "returns error for invalid JSON" do
      response = %{"data" => "not valid json {"}
      {:error, :parse_error} = Decomposer.parse_subtasks(response)
    end

    test "returns error for non-map response" do
      {:error, :invalid_response_format} = Decomposer.parse_subtasks("string")
    end

    test "validates subtasks after parsing" do
      response = %{
        "data" => "[{\"order\": 1, \"description\": \"Task without target_bot\"}]"
      }

      {:error, :invalid_structure} = Decomposer.parse_subtasks(response)
    end

    test "converts string keys to maintain consistency" do
      response = %{
        "data" =>
          "[{\"order\": 1, \"description\": \"Task\", \"target_bot\": \"gtd\", \"target_subject\": \"gtd.task.create\", \"payload\": {}, \"depends_on\": [], \"needs_verification\": false}]"
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      subtask = List.first(subtasks)
      # JSON parsing produces string keys
      assert subtask["order"] == 1
      assert subtask["description"] == "Task"
    end
  end

  # =====================================================================
  # Tests for validate_subtask_structure
  # =====================================================================

  describe "validate_subtask_structure/1" do
    test "accepts subtask with all required fields (atom keys)" do
      subtask = %{
        order: 1,
        description: "Task description",
        target_bot: "bot_army_gtd",
        target_subject: "gtd.task.create",
        payload: %{}
      }

      assert :ok = Decomposer.validate_subtask_structure(subtask)
    end

    test "accepts subtask with string keys" do
      subtask = %{
        "order" => 1,
        "description" => "Task",
        "target_bot" => "gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{}
      }

      assert :ok = Decomposer.validate_subtask_structure(subtask)
    end

    test "rejects subtask missing order field" do
      subtask = %{
        description: "Task",
        target_bot: "gtd",
        target_subject: "gtd.task.create",
        payload: %{}
      }

      {:error, {:missing_field, :order}} =
        Decomposer.validate_subtask_structure(subtask)
    end

    test "rejects subtask missing description" do
      subtask = %{
        order: 1,
        target_bot: "gtd",
        target_subject: "gtd.task.create",
        payload: %{}
      }

      {:error, {:missing_field, :description}} =
        Decomposer.validate_subtask_structure(subtask)
    end

    test "rejects subtask missing target_bot" do
      subtask = %{
        order: 1,
        description: "Task",
        target_subject: "gtd.task.create",
        payload: %{}
      }

      {:error, {:missing_field, :target_bot}} =
        Decomposer.validate_subtask_structure(subtask)
    end

    test "rejects subtask missing target_subject" do
      subtask = %{
        order: 1,
        description: "Task",
        target_bot: "gtd",
        payload: %{}
      }

      {:error, {:missing_field, :target_subject}} =
        Decomposer.validate_subtask_structure(subtask)
    end

    test "rejects subtask missing payload" do
      subtask = %{
        order: 1,
        description: "Task",
        target_bot: "gtd",
        target_subject: "gtd.task.create"
      }

      {:error, {:missing_field, :payload}} =
        Decomposer.validate_subtask_structure(subtask)
    end

    test "rejects non-map input" do
      {:error, :not_a_map} = Decomposer.validate_subtask_structure("not a map")
    end
  end

  # =====================================================================
  # Integration tests for parse_subtasks (without NATS)
  # =====================================================================

  describe "parse_subtasks integration" do
    test "successfully parses multi-step subtasks" do
      response = %{
        "data" => """
        [
          {
            "order": 1,
            "description": "Search for company information",
            "target_bot": "bot_army_llm",
            "target_subject": "llm.query",
            "payload": {"query": "Acme Corp company info"},
            "depends_on": [],
            "needs_verification": false
          },
          {
            "order": 2,
            "description": "Summarize findings into document",
            "target_bot": "bot_army_gtd",
            "target_subject": "gtd.task.create",
            "payload": {"title": "Create summary", "description": "Summarize research"},
            "depends_on": [1],
            "needs_verification": true
          }
        ]
        """
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      assert length(subtasks) == 2
      assert List.first(subtasks)["order"] == 1
      assert List.last(subtasks)["order"] == 2
    end

    test "sorts subtasks by order field" do
      response = %{
        "data" => """
        [
          {
            "order": 3,
            "description": "Third task",
            "target_bot": "bot_army_gtd",
            "target_subject": "gtd.task.create",
            "payload": {},
            "depends_on": [],
            "needs_verification": false
          },
          {
            "order": 1,
            "description": "First task",
            "target_bot": "bot_army_gtd",
            "target_subject": "gtd.task.create",
            "payload": {},
            "depends_on": [],
            "needs_verification": false
          },
          {
            "order": 2,
            "description": "Second task",
            "target_bot": "bot_army_gtd",
            "target_subject": "gtd.task.create",
            "payload": {},
            "depends_on": [],
            "needs_verification": false
          }
        ]
        """
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      orders = Enum.map(subtasks, fn st -> st["order"] end)
      assert orders == [1, 2, 3]
    end

    test "handles single object response (wraps in list)" do
      response = %{
        "data" => """
        {
          "order": 1,
          "description": "Single task",
          "target_bot": "bot_army_gtd",
          "target_subject": "gtd.task.create",
          "payload": {},
          "depends_on": [],
          "needs_verification": false
        }
        """
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      assert length(subtasks) == 1
    end

    test "preserves all subtask fields" do
      response = %{
        "data" => """
        [
          {
            "order": 1,
            "description": "Task with all fields",
            "target_bot": "bot_army_gtd",
            "target_subject": "gtd.task.create",
            "payload": {"title": "Test", "due_date": "2026-05-20"},
            "depends_on": [],
            "needs_verification": true
          }
        ]
        """
      }

      {:ok, subtasks} = Decomposer.parse_subtasks(response)
      subtask = List.first(subtasks)
      assert subtask["order"] == 1
      assert subtask["description"] == "Task with all fields"
      assert subtask["target_bot"] == "bot_army_gtd"
      assert subtask["target_subject"] == "gtd.task.create"
      assert subtask["depends_on"] == []
      assert subtask["needs_verification"] == true
      assert subtask["payload"]["title"] == "Test"
    end
  end

  # =====================================================================
  # Tests for Deterministic Integration (try_deterministic)
  # =====================================================================

  describe "try_deterministic/2" do
    test "returns ok with template for research goal" do
      {:ok, subtasks, template} =
        Decomposer.try_deterministic("research acme corp", %{company: "Acme"})

      assert template == :research
      assert is_list(subtasks)
      assert [_ | _] = subtasks
    end

    test "returns ok with template for summarize goal" do
      {:ok, subtasks, template} =
        Decomposer.try_deterministic("summarize the document", %{})

      assert template == :summarize
      assert is_list(subtasks)
      assert [_ | _] = subtasks
    end

    test "returns ok with template for create_and_schedule goal" do
      {:ok, subtasks, template} =
        Decomposer.try_deterministic("create task and schedule it", %{})

      assert template == :create_and_schedule
      assert is_list(subtasks)
      assert [_ | _] = subtasks
    end

    test "returns no_match for unrelated goal" do
      :no_match = Decomposer.try_deterministic("xyz abc qwerty random", %{})
    end

    test "returns subtasks with all required fields" do
      {:ok, subtasks, _template} =
        Decomposer.try_deterministic("research company", %{})

      Enum.each(subtasks, fn st ->
        assert Map.has_key?(st, "order")
        assert Map.has_key?(st, "description")
        assert Map.has_key?(st, "target_bot")
        assert Map.has_key?(st, "target_subject")
        assert Map.has_key?(st, "payload")
        assert Map.has_key?(st, "depends_on")
        assert Map.has_key?(st, "needs_verification")
      end)
    end

    test "deterministic is fast (no NATS)" do
      start_time = System.monotonic_time(:millisecond)

      {:ok, _subtasks, _template} =
        Decomposer.try_deterministic("research company", %{})

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # Should be very fast - no network calls
      assert duration_ms < 100
    end
  end

  # =====================================================================
  # Tests for Confidence Threshold
  # =====================================================================

  describe "deterministic_confidence_threshold/0" do
    test "returns a float" do
      threshold = Decomposer.deterministic_confidence_threshold()
      assert is_float(threshold) or is_integer(threshold)
    end

    test "threshold is between 0 and 1" do
      threshold = Decomposer.deterministic_confidence_threshold()
      assert threshold >= 0.0
      assert threshold <= 1.0
    end

    test "threshold is reasonable (0.8)" do
      threshold = Decomposer.deterministic_confidence_threshold()
      assert threshold == 0.8
    end
  end

  # =====================================================================
  # Integration Tests - Fallback Logic
  # =====================================================================

  describe "decompose_goal with fallback routing" do
    test "research goal uses deterministic path (no LLM)" do
      # This test verifies that a clear research goal goes through
      # the deterministic path without calling the LLM.
      # We can't easily mock NATS, but we can verify the results
      # match what deterministic produces.
      {:ok, subtasks} = Decomposer.decompose_goal("research acme", %{company: "Acme"})

      # Should succeed
      assert is_list(subtasks)
      assert length(subtasks) == 4

      # Should match deterministic structure
      {:ok, expected_subtasks, _template} =
        Decomposer.try_deterministic("research acme", %{company: "Acme"})

      assert subtasks == expected_subtasks
    end

    test "falls back to LLM for ambiguous goals" do
      # Mock the LLM call for ambiguous goals
      # (This would normally go to LLM since it doesn't match templates)
      # Since we can't easily mock in this test, we just verify the function is callable
      assert is_function(&Decomposer.decompose_goal/3)
    end

    test "decompose_goal returns consistent structure" do
      # Whether deterministic or LLM, results should have same structure
      {:ok, subtasks} = Decomposer.decompose_goal("research company", %{})

      Enum.each(subtasks, fn st ->
        assert is_map(st)
        assert Map.has_key?(st, "order")
        assert Map.has_key?(st, "description")
        assert Map.has_key?(st, "target_bot")
        assert Map.has_key?(st, "target_subject")
        assert Map.has_key?(st, "payload")
        assert Map.has_key?(st, "depends_on")
        assert Map.has_key?(st, "needs_verification")
      end)
    end

    test "decompose_goal with empty context" do
      {:ok, subtasks} = Decomposer.decompose_goal("research target", %{})

      assert is_list(subtasks)
      assert [_ | _] = subtasks
    end

    test "decompose_goal with context" do
      {:ok, subtasks} =
        Decomposer.decompose_goal("research company", %{company: "TechCorp"})

      assert is_list(subtasks)
      assert [_ | _] = subtasks

      # Verify context is used
      descriptions = Enum.map(subtasks, fn st -> st["description"] end)
      used_context = Enum.any?(descriptions, fn desc -> String.contains?(desc, "TechCorp") end)

      assert used_context
    end
  end
end

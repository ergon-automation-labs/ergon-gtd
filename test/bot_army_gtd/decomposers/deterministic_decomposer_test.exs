defmodule BotArmyGtd.Decomposers.DeterministicDecomposerTest do
  use ExUnit.Case
  @moduletag :decomposers

  alias BotArmyGtd.Decomposers.DeterministicDecomposer

  # =====================================================================
  # Tests for match_template
  # =====================================================================

  describe "match_template/1" do
    test "matches research template correctly" do
      {template, confidence} = DeterministicDecomposer.match_template("research acme corp")

      assert template == :research
      assert confidence > 0.5
    end

    test "matches research template with investigate keyword" do
      {template, confidence} =
        DeterministicDecomposer.match_template("investigate competitor activity")

      assert template == :research
      assert confidence > 0.5
    end

    test "matches research template with explore keyword" do
      {template, confidence} = DeterministicDecomposer.match_template("explore market trends")

      assert template == :research
      assert confidence > 0.5
    end

    test "matches summarize template correctly" do
      {template, confidence} = DeterministicDecomposer.match_template("summarize the document")

      assert template == :summarize
      assert confidence > 0.5
    end

    test "matches create_and_schedule template correctly" do
      {template, confidence} =
        DeterministicDecomposer.match_template("create task and schedule for next week")

      assert template == :create_and_schedule
      assert confidence > 0.5
    end

    test "matches email_workflow template correctly" do
      {template, confidence} = DeterministicDecomposer.match_template("draft email to john")

      assert template == :email_workflow
      assert confidence > 0.5
    end

    test "matches analysis template correctly" do
      {template, confidence} = DeterministicDecomposer.match_template("analyze the data")

      assert template == :analysis
      assert confidence > 0.5
    end

    test "returns high confidence for clear matches" do
      {_template, confidence} = DeterministicDecomposer.match_template("research acme corp")

      assert confidence > 0.8
    end

    test "returns confidence between 0 and 1" do
      {_template, confidence} = DeterministicDecomposer.match_template("do something random")

      assert confidence >= 0.0
      assert confidence <= 1.0
    end

    test "case insensitive matching" do
      {template1, confidence1} =
        DeterministicDecomposer.match_template("Research Company X")

      {template2, confidence2} =
        DeterministicDecomposer.match_template("research company x")

      assert template1 == template2
      assert confidence1 == confidence2
    end

    test "returns no_match tuple for unmatched goals" do
      {template, confidence} = DeterministicDecomposer.match_template("xyz abc qwerty")

      assert template == :no_match
      assert confidence == 0.0
    end
  end

  # =====================================================================
  # Tests for templates
  # =====================================================================

  describe "templates/0" do
    test "returns list of available templates" do
      templates = DeterministicDecomposer.templates()

      assert is_list(templates)
      assert length(templates) > 0
    end

    test "includes research template" do
      templates = DeterministicDecomposer.templates()

      assert :research in templates
    end

    test "includes summarize template" do
      templates = DeterministicDecomposer.templates()

      assert :summarize in templates
    end

    test "includes create_and_schedule template" do
      templates = DeterministicDecomposer.templates()

      assert :create_and_schedule in templates
    end

    test "includes email_workflow template" do
      templates = DeterministicDecomposer.templates()

      assert :email_workflow in templates
    end

    test "includes analysis template" do
      templates = DeterministicDecomposer.templates()

      assert :analysis in templates
    end

    test "all returned items are atoms" do
      templates = DeterministicDecomposer.templates()

      Enum.each(templates, fn t -> assert is_atom(t) end)
    end
  end

  # =====================================================================
  # Tests for decompose_from_template - Research
  # =====================================================================

  describe "decompose_from_template/3 - research" do
    test "decomposes research goal into 4 subtasks" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research acme corp",
          %{company: "Acme Corp"},
          :research
        )

      assert length(subtasks) == 4
    end

    test "research subtasks are in correct order" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research acme corp",
          %{},
          :research
        )

      orders = Enum.map(subtasks, fn st -> st["order"] end)
      assert orders == [1, 2, 3, 4]
    end

    test "research subtasks have all required fields" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research company",
          %{},
          :research
        )

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

    test "research has proper dependencies" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research acme",
          %{},
          :research
        )

      # First task has no dependencies
      assert List.first(subtasks)["depends_on"] == []

      # Second depends on first
      assert Enum.at(subtasks, 1)["depends_on"] == [1]

      # Third depends on second
      assert Enum.at(subtasks, 2)["depends_on"] == [2]

      # Fourth depends on third
      assert Enum.at(subtasks, 3)["depends_on"] == [3]
    end

    test "research first subtask targets LLM" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research acme",
          %{},
          :research
        )

      first = List.first(subtasks)
      assert first["target_bot"] == "bot_army_llm"
      assert first["target_subject"] == "bot_army_llm.query"
    end

    test "research last subtask needs verification" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research acme",
          %{},
          :research
        )

      last = List.last(subtasks)
      assert last["needs_verification"] == true
    end

    test "research uses context company name" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research company",
          %{company: "Acme Corp"},
          :research
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "Acme Corp")
    end

    test "research falls back to default company name" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research company",
          %{},
          :research
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "target")
    end
  end

  # =====================================================================
  # Tests for decompose_from_template - Summarize
  # =====================================================================

  describe "decompose_from_template/3 - summarize" do
    test "decomposes summarize goal into 4 subtasks" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "summarize the document",
          %{},
          :summarize
        )

      assert length(subtasks) == 4
    end

    test "summarize subtasks are in correct order" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "summarize the document",
          %{},
          :summarize
        )

      orders = Enum.map(subtasks, fn st -> st["order"] end)
      assert orders == [1, 2, 3, 4]
    end

    test "summarize has proper dependencies" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "summarize document",
          %{},
          :summarize
        )

      assert List.first(subtasks)["depends_on"] == []
      assert Enum.at(subtasks, 1)["depends_on"] == [1]
      assert Enum.at(subtasks, 2)["depends_on"] == [2]
      assert Enum.at(subtasks, 3)["depends_on"] == [3]
    end

    test "summarize uses context source" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "summarize content",
          %{source: "blog post"},
          :summarize
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "blog post")
    end

    test "summarize uses context format" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "summarize content",
          %{format: "bullet points"},
          :summarize
        )

      third = Enum.at(subtasks, 2)
      assert String.contains?(third["description"], "bullet points")
    end

    test "summarize last subtask needs verification" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "summarize document",
          %{},
          :summarize
        )

      last = List.last(subtasks)
      assert last["needs_verification"] == true
    end
  end

  # =====================================================================
  # Tests for decompose_from_template - Create and Schedule
  # =====================================================================

  describe "decompose_from_template/3 - create_and_schedule" do
    test "decomposes create_and_schedule goal with notification" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task and schedule",
          %{notify: true},
          :create_and_schedule
        )

      assert length(subtasks) == 3
    end

    test "decomposes create_and_schedule without notification" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task and schedule",
          %{notify: false},
          :create_and_schedule
        )

      assert length(subtasks) == 2
    end

    test "create_and_schedule first step creates task" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task",
          %{},
          :create_and_schedule
        )

      first = List.first(subtasks)
      assert first["target_subject"] == "gtd.task.create"
      assert String.contains?(first["description"], "Create")
    end

    test "create_and_schedule second step sets deadline" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task",
          %{},
          :create_and_schedule
        )

      second = Enum.at(subtasks, 1)
      assert second["target_subject"] == "gtd.task.update"
      assert String.contains?(second["description"], "Set deadline")
    end

    test "create_and_schedule uses context deadline" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task",
          %{deadline: "2026-05-30"},
          :create_and_schedule
        )

      second = Enum.at(subtasks, 1)
      assert String.contains?(second["description"], "2026-05-30")
    end

    test "create_and_schedule notification targets synapse" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task",
          %{notify: true},
          :create_and_schedule
        )

      third = Enum.at(subtasks, 2)
      assert third["target_bot"] == "bot_army_synapse"
      assert third["target_subject"] == "synapse.notify"
    end

    test "create_and_schedule has proper dependencies" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "create task",
          %{notify: true},
          :create_and_schedule
        )

      assert List.first(subtasks)["depends_on"] == []
      assert Enum.at(subtasks, 1)["depends_on"] == [1]
      assert Enum.at(subtasks, 2)["depends_on"] == [2]
    end
  end

  # =====================================================================
  # Tests for decompose_from_template - Email Workflow
  # =====================================================================

  describe "decompose_from_template/3 - email_workflow" do
    test "decomposes email_workflow goal into 3 subtasks" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email to john",
          %{},
          :email_workflow
        )

      assert length(subtasks) == 3
    end

    test "email_workflow subtasks are in correct order" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email",
          %{},
          :email_workflow
        )

      orders = Enum.map(subtasks, fn st -> st["order"] end)
      assert orders == [1, 2, 3]
    end

    test "email_workflow first step drafts email" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email to john",
          %{recipient: "john"},
          :email_workflow
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "Draft email")
      assert String.contains?(first["description"], "john")
    end

    test "email_workflow second step reviews draft" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email",
          %{},
          :email_workflow
        )

      second = Enum.at(subtasks, 1)
      assert String.contains?(second["description"], "Review")
      assert second["depends_on"] == [1]
    end

    test "email_workflow third step sends email" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email",
          %{},
          :email_workflow
        )

      third = List.last(subtasks)
      assert String.contains?(third["description"], "Send")
      assert third["depends_on"] == [2]
      assert third["needs_verification"] == true
    end

    test "email_workflow uses context recipient" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email",
          %{recipient: "alice@example.com"},
          :email_workflow
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "alice@example.com")
    end

    test "email_workflow uses context subject" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "draft email",
          %{subject: "Project Update"},
          :email_workflow
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "Project Update")
    end
  end

  # =====================================================================
  # Tests for decompose_from_template - Analysis
  # =====================================================================

  describe "decompose_from_template/3 - analysis" do
    test "decomposes analysis goal into 4 subtasks" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze the data",
          %{},
          :analysis
        )

      assert length(subtasks) == 4
    end

    test "analysis subtasks are in correct order" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze data",
          %{},
          :analysis
        )

      orders = Enum.map(subtasks, fn st -> st["order"] end)
      assert orders == [1, 2, 3, 4]
    end

    test "analysis has proper dependencies" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze data",
          %{},
          :analysis
        )

      assert List.first(subtasks)["depends_on"] == []
      assert Enum.at(subtasks, 1)["depends_on"] == [1]
      assert Enum.at(subtasks, 2)["depends_on"] == [2]
      assert Enum.at(subtasks, 3)["depends_on"] == [3]
    end

    test "analysis first step gathers data" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze data",
          %{data_source: "sales database"},
          :analysis
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "Gather")
      assert String.contains?(first["description"], "sales database")
    end

    test "analysis second step computes metric" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze data",
          %{metric: "revenue growth"},
          :analysis
        )

      second = Enum.at(subtasks, 1)
      assert String.contains?(second["description"], "Compute")
      assert String.contains?(second["description"], "revenue growth")
    end

    test "analysis third step interprets results" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze data",
          %{},
          :analysis
        )

      third = Enum.at(subtasks, 2)
      assert String.contains?(third["description"], "Interpret")
    end

    test "analysis last step reports findings" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "analyze data",
          %{},
          :analysis
        )

      last = List.last(subtasks)
      assert String.contains?(last["description"], "report")
      assert last["needs_verification"] == true
    end
  end

  # =====================================================================
  # Tests for decompose_from_template - Error Cases
  # =====================================================================

  describe "decompose_from_template/3 - error handling" do
    test "returns error for unknown template" do
      {:error, :unknown_template} =
        DeterministicDecomposer.decompose_from_template(
          "some goal",
          %{},
          :unknown_template
        )
    end

    test "succeeds with empty context" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research company",
          %{},
          :research
        )

      assert length(subtasks) > 0
    end

    test "succeeds with no context argument" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research company",
          :research
        )

      assert length(subtasks) > 0
    end

    test "handles string keys in context" do
      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(
          "research company",
          %{"company" => "Acme"},
          :research
        )

      first = List.first(subtasks)
      assert String.contains?(first["description"], "Acme")
    end
  end

  # =====================================================================
  # Integration Tests
  # =====================================================================

  describe "deterministic decomposition flow" do
    test "match then decompose with research" do
      goal = "research competitor strategies"

      {template, confidence} = DeterministicDecomposer.match_template(goal)

      assert template == :research
      assert confidence > 0.5

      {:ok, subtasks} =
        DeterministicDecomposer.decompose_from_template(goal, %{}, template)

      assert length(subtasks) > 0

      Enum.each(subtasks, fn st ->
        assert Map.has_key?(st, "order")
        assert Map.has_key?(st, "description")
        assert Map.has_key?(st, "target_bot")
        assert Map.has_key?(st, "target_subject")
        assert Map.has_key?(st, "payload")
      end)
    end

    test "all templates produce valid subtask structure" do
      templates = DeterministicDecomposer.templates()

      Enum.each(templates, fn template ->
        {:ok, subtasks} =
          DeterministicDecomposer.decompose_from_template("test goal", %{}, template)

        Enum.each(subtasks, fn st ->
          assert is_integer(st["order"]), "order must be integer for #{template}"
          assert is_binary(st["description"]), "description must be binary for #{template}"
          assert is_binary(st["target_bot"]), "target_bot must be binary for #{template}"
          assert is_binary(st["target_subject"]), "target_subject must be binary for #{template}"
          assert is_map(st["payload"]), "payload must be map for #{template}"
          assert is_list(st["depends_on"]), "depends_on must be list for #{template}"

          assert is_boolean(st["needs_verification"]),
                 "needs_verification must be boolean for #{template}"
        end)
      end)
    end

    test "deterministic results are consistent" do
      goal = "research acme"
      context = %{company: "Acme"}
      template = :research

      {:ok, subtasks1} =
        DeterministicDecomposer.decompose_from_template(goal, context, template)

      {:ok, subtasks2} =
        DeterministicDecomposer.decompose_from_template(goal, context, template)

      # Same input should produce identical output
      assert subtasks1 == subtasks2
    end

    test "deterministic decomposition is fast (no NATS calls)" do
      goal = "research company"

      start_time = System.monotonic_time(:millisecond)

      {:ok, _subtasks} =
        DeterministicDecomposer.decompose_from_template(goal, %{}, :research)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # Should be nearly instant (< 100ms) - no network latency
      assert duration_ms < 100
    end
  end
end

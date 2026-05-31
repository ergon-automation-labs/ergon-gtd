defmodule BotArmyGtd.ReflectionEvaluator do
  @moduledoc """
  Evaluates decomposition quality via self-critique before execution.

  Scores decompositions on three dimensions:
  1. Atomicity: Are subtasks 1-2 hour chunks (not too big)?
  2. Dependency order: Is the execution sequence correct?
  3. Completeness: Are all prerequisites captured?

  Returns reflection_score (1-5) + reflection_notes for gating.

  ## Example

      {:ok, score, notes} = ReflectionEvaluator.evaluate_decomposition(
        subtasks,
        "hire senior engineer"
      )

      if score >= 4 do
        Orchestrator.execute(subtasks)
      else
        {:error, notes}
      end
  """

  require Logger

  @doc """
  Evaluate a decomposition on three criteria.

  Returns: {:ok, score_1_to_5, notes_string}
  """
  def evaluate_decomposition(subtasks, goal \\ "task") when is_list(subtasks) do
    Logger.info(
      "[ReflectionEvaluator] Evaluating #{length(subtasks)} subtasks for: #{String.slice(goal, 0, 50)}"
    )

    atomicity_score = evaluate_atomicity(subtasks)
    dependency_score = evaluate_dependencies(subtasks)
    completeness_score = evaluate_completeness(subtasks)

    # If any dimension scores <= 4, it indicates a problem
    # Otherwise all dimensions are excellent (5), so overall is excellent
    scores = [atomicity_score, dependency_score, completeness_score]
    min_score = Enum.min(scores)

    avg_score =
      cond do
        # If any dimension is < 4, overall is poor
        min_score < 4 ->
          min(3, round(Enum.sum(scores) / length(scores)))

        # If any dimension is exactly 4 (but not all 5), overall is good not excellent
        min_score == 4 ->
          3

        # All dimensions are 5: excellent
        true ->
          5
      end

    notes = build_notes(atomicity_score, dependency_score, completeness_score, goal)

    Logger.info("[ReflectionEvaluator] Final score: #{avg_score}/5",
      atomicity: atomicity_score,
      dependency: dependency_score,
      completeness: completeness_score
    )

    {:ok, avg_score, notes}
  end

  # ============================================================================
  # Criterion 1: Atomicity — are subtasks in 1-2 hour chunks?
  # ============================================================================

  defp evaluate_atomicity(subtasks) do
    # Heuristics for detecting over-scoped tasks
    over_scoped =
      Enum.count(subtasks, fn subtask ->
        desc = Map.get(subtask, "description", "")

        cond do
          # Long descriptions often indicate over-scoped work
          String.length(desc) > 150 -> true
          # Multiple action words suggest bundled tasks
          String.contains?(desc, ["and then", "also", "plus", "additionally"]) -> true
          # Multiple domains in one task
          domain_count(desc) > 1 -> true
          true -> false
        end
      end)

    # Score: 5 if all atomic, 3-4 if some bundling, 1-2 if heavily bundled
    case over_scoped do
      0 -> 5
      n when n <= div(length(subtasks), 3) -> 4
      n when n <= div(length(subtasks), 2) -> 3
      _ -> 2
    end
  end

  defp domain_count(description) do
    domains = ["llm", "gtd", "feeds", "synapse", "advocacy", "database", "api", "ui"]

    Enum.count(domains, fn domain ->
      String.contains?(String.downcase(description), domain)
    end)
  end

  # ============================================================================
  # Criterion 2: Dependency Order — is execution sequence correct?
  # ============================================================================

  defp evaluate_dependencies(subtasks) do
    # Normalize subtasks to use order numbers for dependency checking
    indexed_subtasks =
      Enum.map(subtasks, fn subtask ->
        order = Map.get(subtask, "order", 0)
        depends_on = Map.get(subtask, "depends_on", [])
        {order, subtask, depends_on}
      end)

    # Check for forward references: depends on a task with order >= current order
    dependency_errors =
      Enum.count(indexed_subtasks, fn {order, _subtask, depends_on} ->
        Enum.any?(depends_on, fn dep_order ->
          # Forward reference if dependency order >= current order
          dep_order >= order
        end)
      end)

    # Check for disconnected components (orphaned subtasks)
    orphan_count = count_orphaned_subtasks(indexed_subtasks)

    total_issues = dependency_errors + orphan_count

    case total_issues do
      # Perfect DAG
      0 -> 5
      # Minor issue
      n when n == 1 -> 4
      # Some issues
      n when n <= div(length(subtasks), 3) -> 3
      # Major dependency problems
      _ -> 2
    end
  end

  defp count_orphaned_subtasks(indexed_subtasks) do
    # indexed_subtasks: [{order, subtask, depends_on}, ...]
    # Find tasks that have no incoming or outgoing edges
    all_orders = Enum.map(indexed_subtasks, fn {order, _, _} -> order end)

    Enum.count(indexed_subtasks, fn {order, _subtask, depends_on} ->
      # No incoming edges (not depended on by anyone)
      no_incoming = !Enum.any?(indexed_subtasks, fn {_, _, other_deps} -> order in other_deps end)

      # No outgoing edges (doesn't depend on anyone)
      no_outgoing = Enum.empty?(depends_on)

      # Orphaned if isolated and not the first task
      no_incoming && no_outgoing && order != Enum.min(all_orders)
    end)
  end

  # ============================================================================
  # Criterion 3: Completeness — are prerequisites captured?
  # ============================================================================

  defp evaluate_completeness(subtasks) do
    # Check for common missing prerequisites
    missing_count =
      Enum.count(subtasks, fn subtask ->
        target_bot = Map.get(subtask, "target_bot", "")
        payload = Map.get(subtask, "payload", %{})
        desc = Map.get(subtask, "description", "")

        cond do
          # LLM tasks need a query or prompt
          String.contains?(target_bot, "llm") && !has_query(payload) -> true
          # GTD tasks need a title
          String.contains?(target_bot, "gtd") && !has_title(payload) -> true
          # Feed tasks need content
          String.contains?(target_bot, "feed") && !has_content(payload) -> true
          # Any task with vague description
          String.contains?(desc, ["TBD", "TODO", "fill in", "???"]) -> true
          true -> false
        end
      end)

    # Bonus: check if subtasks reference available resources (improves quality)
    context_references =
      Enum.count(subtasks, fn subtask ->
        has_resource_reference(subtask)
      end)

    context_score_bonus =
      if context_references > 0 do
        min(1, div(context_references * 100, length(subtasks)) / 100)
      else
        0
      end

    base_score =
      case missing_count do
        # All prerequisites present
        0 -> 5
        # One missing detail
        n when n == 1 -> 4
        # Several missing
        n when n <= div(length(subtasks), 2) -> 3
        # Major gaps
        _ -> 2
      end

    # Bonus up to +1 for referencing context
    final_score = min(5, base_score + context_score_bonus)
    round(final_score)
  end

  defp has_query(payload) do
    Map.has_key?(payload, "query") || Map.has_key?(payload, "prompt")
  end

  defp has_title(payload) do
    Map.has_key?(payload, "title") || Map.has_key?(payload, "description")
  end

  defp has_content(payload) do
    Map.has_key?(payload, "content") || Map.has_key?(payload, "text")
  end

  defp has_resource_reference(subtask) do
    # Check if subtask references available resources (docs, runbooks, examples)
    desc = Map.get(subtask, "description", "")
    payload = Map.get(subtask, "payload", %{})

    # Look for common resource references in description or payload
    resource_keywords = [
      "docs",
      "guide",
      "runbook",
      "example",
      "reference",
      "template",
      "sample",
      "see also",
      "find in",
      "check",
      "documented"
    ]

    desc_has_ref =
      resource_keywords
      |> Enum.any?(fn keyword -> String.contains?(String.downcase(desc), keyword) end)

    payload_str = inspect(payload) |> String.downcase()
    payload_has_ref = Enum.any?(resource_keywords, fn k -> String.contains?(payload_str, k) end)

    # Bonus: if subtask has context enrichment, consider it referenced
    has_context = Map.has_key?(subtask, "context")

    desc_has_ref || payload_has_ref || has_context
  end

  # ============================================================================
  # Build reflection notes
  # ============================================================================

  defp build_notes(atomicity, dependency, completeness, goal) do
    issues = []

    issues =
      if atomicity <= 4 do
        issues ++ ["Some subtasks may be over-scoped (too big for 1-2 hours)"]
      else
        issues
      end

    issues =
      if dependency <= 4 do
        issues ++ ["Dependency graph has issues (forward refs or orphans)"]
      else
        issues
      end

    issues =
      if completeness <= 4 do
        issues ++ ["Some subtasks missing prerequisites (query, title, content)"]
      else
        issues
      end

    goal_prefix = "Goal: #{String.slice(goal, 0, 60)}\n"

    if Enum.empty?(issues) do
      goal_prefix <>
        "Decomposition quality is excellent. All criteria met: atomic subtasks, clean dependency order, complete prerequisites."
    else
      goal_prefix <> "Issues found:\n" <> Enum.map_join(issues, "\n", &"  - #{&1}")
    end
  end
end

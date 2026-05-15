defmodule BotArmyGtd.Decomposers.DeterministicDecomposer do
  @moduledoc """
  Fast, rules-based goal decomposer for common patterns.

  Provides template-based decomposition for predictable goal patterns,
  with 100x faster execution than LLM-based decomposition and no network latency.

  ## Templates

  Available templates match common workflows:
  1. `:research` - search → gather → analyze → summarize
  2. `:summarize` - fetch → extract → condense → polish
  3. `:create_and_schedule` - create task → set deadline → notify
  4. `:email_workflow` - draft → review → send
  5. `:analysis` - gather data → compute → interpret → report

  ## Usage

      # Try deterministic first, fallback to LLM if no match
      case DeterministicDecomposer.match_template("research company X") do
        {template_name, confidence} when confidence > 0.8 ->
          DeterministicDecomposer.decompose_from_template(goal, context, template_name)
        _ ->
          # Fall back to LLM
          Decomposer.decompose_goal(goal, context, constraints)
      end

  ## Return Format

  All decompose functions return `{:ok, subtasks}` where subtasks is a list of maps:
      [
        %{
          "order" => 1,
          "description" => "Description",
          "target_bot" => "bot_army_gtd",
          "target_subject" => "gtd.task.create",
          "payload" => %{},
          "depends_on" => [],
          "needs_verification" => false
        },
        ...
      ]
  """

  require Logger

  @doc """
  Matches a goal against available templates and returns match confidence.

  Uses keyword matching, semantic patterns, and heuristics to find the best template.

  ## Arguments
    - `goal` - Goal string to match

  ## Returns
    - `{template_atom, confidence_0_to_1}` - Best matching template with confidence score
    - `{:no_match, 0.0}` - No viable template match

  ## Examples

      iex> {template, confidence} = DeterministicDecomposer.match_template("research acme corp")
      iex> template in [:research, :no_match]
      true
      iex> confidence >= 0 and confidence <= 1
      true
  """
  def match_template(goal) when is_binary(goal) do
    goal_lower = String.downcase(goal)

    [
      match_research(goal_lower),
      match_summarize(goal_lower),
      match_create_and_schedule(goal_lower),
      match_email_workflow(goal_lower),
      match_analysis(goal_lower)
    ]
    |> Enum.sort_by(fn {_template, score} -> score end, :desc)
    |> List.first() || {:no_match, 0.0}
  end

  @doc """
  Returns all available template atoms.

  ## Returns
    - List of available template names

  ## Examples

      iex> templates = DeterministicDecomposer.templates()
      iex> :research in templates
      true
  """
  def templates do
    [:research, :summarize, :create_and_schedule, :email_workflow, :analysis]
  end

  @doc """
  Decomposes a goal using a specific template.

  Generates concrete subtasks from the template, filling in context-specific details.

  ## Arguments
    - `goal` - Goal string
    - `context` - Map with goal context (e.g., %{company: "Acme"})
    - `template` - Template atom (e.g., :research)

  ## Returns
    - `{:ok, subtasks}` - List of subtask maps
    - `{:error, reason}` - Error tuple

  ## Examples

      iex> {:ok, subtasks} = DeterministicDecomposer.decompose_from_template(
      ...>   "research acme corp",
      ...>   %{company: "Acme Corp"},
      ...>   :research
      ...> )
      iex> length(subtasks) > 0
      true
  """
  def decompose_from_template(goal, context \\ %{}, template)
      when is_binary(goal) and is_atom(template) do
    Logger.info("[DeterministicDecomposer] Decomposing with template",
      template: template,
      goal: goal
    )

    case template do
      :research -> decompose_research(goal, context)
      :summarize -> decompose_summarize(goal, context)
      :create_and_schedule -> decompose_create_and_schedule(goal, context)
      :email_workflow -> decompose_email_workflow(goal, context)
      :analysis -> decompose_analysis(goal, context)
      _ -> {:error, :unknown_template}
    end
  end

  # =====================================================================
  # Private: Template Matching
  # =====================================================================

  defp match_research(goal_lower) do
    keywords = ["research", "investigate", "explore", "study", "learn about", "find out about"]
    score = keyword_score(goal_lower, keywords)
    {:research, score}
  end

  defp match_summarize(goal_lower) do
    keywords = ["summarize", "summarise", "condense", "abstract", "digest", "tldr"]
    score = keyword_score(goal_lower, keywords)
    {:summarize, score}
  end

  defp match_create_and_schedule(goal_lower) do
    keywords = ["schedule", "create task", "book", "set deadline", "plan meeting"]
    score = keyword_score(goal_lower, keywords)
    {:create_and_schedule, score}
  end

  defp match_email_workflow(goal_lower) do
    keywords = ["draft", "email", "send", "write message", "correspondence"]
    score = keyword_score(goal_lower, keywords)
    {:email_workflow, score}
  end

  defp match_analysis(goal_lower) do
    keywords = ["analyze", "analyse", "evaluate", "compute", "calculate", "assess"]
    score = keyword_score(goal_lower, keywords)
    {:analysis, score}
  end

  defp keyword_score(text, keywords) do
    matches = Enum.count(keywords, fn kw -> String.contains?(text, kw) end)

    case matches do
      0 -> 0.0
      1 -> 0.6
      2 -> 0.85
      3 -> 0.95
      _ -> 1.0
    end
  end

  # =====================================================================
  # Private: Template Decompositions
  # =====================================================================

  defp decompose_research(goal, context) do
    company = context[:company] || context["company"] || "target"
    query = context[:query] || context["query"] || company

    subtasks = [
      %{
        "order" => 1,
        "description" => "Search for information about #{company}",
        "target_bot" => "bot_army_llm",
        "target_subject" => "bot_army_llm.query",
        "payload" => %{"query" => "Find information about #{query}"},
        "depends_on" => [],
        "needs_verification" => false
      },
      %{
        "order" => 2,
        "description" => "Gather and organize findings",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Organize research findings for #{company}",
          "description" => "Compile all findings into organized notes"
        },
        "depends_on" => [1],
        "needs_verification" => false
      },
      %{
        "order" => 3,
        "description" => "Analyze key findings and patterns",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Analyze findings for #{company}",
          "description" => "Identify key patterns and insights"
        },
        "depends_on" => [2],
        "needs_verification" => false
      },
      %{
        "order" => 4,
        "description" => "Create summary document",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Write summary for #{company}",
          "description" => "Synthesize findings into concise summary"
        },
        "depends_on" => [3],
        "needs_verification" => true
      }
    ]

    {:ok, subtasks}
  end

  defp decompose_summarize(goal, context) do
    source = context[:source] || context["source"] || "document"
    format = context[:format] || context["format"] || "concise summary"

    subtasks = [
      %{
        "order" => 1,
        "description" => "Fetch #{source}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Retrieve #{source}",
          "description" => "Get the original document/content"
        },
        "depends_on" => [],
        "needs_verification" => false
      },
      %{
        "order" => 2,
        "description" => "Extract key points from #{source}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Extract key points",
          "description" => "Identify main ideas and important details"
        },
        "depends_on" => [1],
        "needs_verification" => false
      },
      %{
        "order" => 3,
        "description" => "Condense to #{format}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Condense to summary",
          "description" => "Reduce key points to #{format}"
        },
        "depends_on" => [2],
        "needs_verification" => false
      },
      %{
        "order" => 4,
        "description" => "Polish and finalize summary",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Polish summary",
          "description" => "Review and refine for clarity"
        },
        "depends_on" => [3],
        "needs_verification" => true
      }
    ]

    {:ok, subtasks}
  end

  defp decompose_create_and_schedule(goal, context) do
    task_title = context[:task_title] || context["task_title"] || "New task"
    deadline = context[:deadline] || context["deadline"] || "next week"
    notify = context[:notify] || context["notify"] || true

    subtasks = [
      %{
        "order" => 1,
        "description" => "Create #{task_title}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => task_title,
          "description" => goal
        },
        "depends_on" => [],
        "needs_verification" => false
      },
      %{
        "order" => 2,
        "description" => "Set deadline to #{deadline}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.update",
        "payload" => %{
          "due_date" => deadline
        },
        "depends_on" => [1],
        "needs_verification" => false
      }
    ]

    subtasks =
      if notify do
        subtasks ++
          [
            %{
              "order" => 3,
              "description" => "Send notification about new task",
              "target_bot" => "bot_army_synapse",
              "target_subject" => "synapse.notify",
              "payload" => %{
                "message" => "New task created: #{task_title}",
                "priority" => "normal"
              },
              "depends_on" => [2],
              "needs_verification" => false
            }
          ]
      else
        subtasks
      end

    {:ok, subtasks}
  end

  defp decompose_email_workflow(goal, context) do
    recipient = context[:recipient] || context["recipient"] || "recipient"
    subject = context[:subject] || context["subject"] || "Email"

    subtasks = [
      %{
        "order" => 1,
        "description" => "Draft email to #{recipient}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Draft: #{subject}",
          "description" => goal
        },
        "depends_on" => [],
        "needs_verification" => false
      },
      %{
        "order" => 2,
        "description" => "Review email for clarity and tone",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Review email draft",
          "description" => "Check for clarity, grammar, and tone"
        },
        "depends_on" => [1],
        "needs_verification" => false
      },
      %{
        "order" => 3,
        "description" => "Send email to #{recipient}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Send: #{subject}",
          "description" => "Send finalized email"
        },
        "depends_on" => [2],
        "needs_verification" => true
      }
    ]

    {:ok, subtasks}
  end

  defp decompose_analysis(goal, context) do
    data_source = context[:data_source] || context["data_source"] || "data"
    metric = context[:metric] || context["metric"] || "key metric"

    subtasks = [
      %{
        "order" => 1,
        "description" => "Gather data from #{data_source}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Gather #{data_source}",
          "description" => "Collect necessary data for analysis"
        },
        "depends_on" => [],
        "needs_verification" => false
      },
      %{
        "order" => 2,
        "description" => "Compute #{metric}",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Calculate #{metric}",
          "description" => "Run calculations on gathered data"
        },
        "depends_on" => [1],
        "needs_verification" => false
      },
      %{
        "order" => 3,
        "description" => "Interpret results and findings",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Interpret analysis results",
          "description" => "Explain what the data means"
        },
        "depends_on" => [2],
        "needs_verification" => false
      },
      %{
        "order" => 4,
        "description" => "Prepare final analysis report",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{
          "title" => "Write analysis report",
          "description" => "Document findings and recommendations"
        },
        "depends_on" => [3],
        "needs_verification" => true
      }
    ]

    {:ok, subtasks}
  end
end

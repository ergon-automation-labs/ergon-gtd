defmodule BotArmyGtd.Decomposer do
  @moduledoc """
  LLM-based goal decomposition module.

  Breaks high-level goals into ordered subtasks by calling the LLM service via NATS.
  Each subtask includes metadata for routing, execution, and verification.

  ## Basic Usage

      {:ok, subtasks} = Decomposer.decompose_goal(
        "research company X and create summary",
        %{company_name: "Acme Corp"},
        %{max_steps: 5, max_duration_minutes: 30}
      )

  ## Expected subtask format

  Each subtask includes:
  - `order`: Integer for execution sequence
  - `description`: What needs to be done
  - `target_bot`: Where to send this task (e.g. "bot_army_gtd")
  - `target_subject`: NATS subject for routing (e.g. "gtd.task.create")
  - `payload`: Task parameters for the target bot
  - `depends_on`: List of order indices this depends on (for sequencing)
  - `needs_verification`: Boolean indicating if factory_breaker should verify

  ## Error Handling

  Returns `{:error, reason}` for:
  - `:timeout` - LLM request timed out
  - `:parse_error` - JSON parsing failed
  - `:invalid_structure` - Subtask missing required fields
  - `:llm_error` - LLM service error
  - `:connection_error` - NATS connection failed
  """

  require Logger

  @default_timeout_ms 10_000
  @default_max_steps 5
  @default_max_duration_minutes 30

  @doc """
  Decomposes a goal into subtasks via LLM.

  Sends the goal to the LLM service with instructions to break it down into
  concrete, ordered subtasks. Validates and returns the parsed subtasks.

  ## Arguments
    - `goal` - High-level goal string (e.g. "research company and create summary")
    - `context` - Map with goal context (e.g. %{company_id: "123"})
    - `constraints` - Map with execution constraints
      - `:max_steps` - Maximum number of subtasks (default: 5)
      - `:max_duration_minutes` - Time budget (default: 30)

  ## Returns
    - `{:ok, subtasks}` - List of validated subtask maps
    - `{:error, reason}` - Error tuple with reason atom

  ## Examples

      iex> {:ok, subtasks} = Decomposer.decompose_goal(
      ...>   "research company",
      ...>   %{},
      ...>   %{}
      ...> )
      iex> length(subtasks) > 0
      true
  """
  def decompose_goal(goal, context \\ %{}, constraints \\ %{}) when is_binary(goal) do
    Logger.info("[Decomposer] Decomposing goal", goal: goal)

    case call_llm(goal, context, constraints) do
      {:ok, response} ->
        case parse_subtasks(response) do
          {:ok, subtasks} ->
            Logger.info(
              "[Decomposer] Successfully decomposed goal into #{length(subtasks)} subtasks"
            )

            {:ok, subtasks}

          {:error, reason} ->
            Logger.error("[Decomposer] Failed to parse subtasks", reason: reason)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[Decomposer] LLM call failed", reason: reason)
        {:error, reason}
    end
  end

  @doc """
  Builds the decomposition prompt for the LLM.

  Constructs a detailed prompt that instructs the LLM to break a goal
  into concrete, executable subtasks with proper metadata.

  ## Arguments
    - `goal` - High-level goal
    - `context` - Goal context
    - `constraints` - Execution constraints

  ## Returns
    - Prompt string ready to send to LLM
  """
  def build_decomposition_prompt(goal, context, constraints) do
    max_steps = constraints[:max_steps] || @default_max_steps
    max_duration = constraints[:max_duration_minutes] || @default_max_duration_minutes

    context_json =
      if map_size(context) > 0 do
        Jason.encode!(context)
      else
        "{}"
      end

    """
    Goal: #{goal}

    Context: #{context_json}

    Constraints:
    - Max steps: #{max_steps}
    - Max duration: #{max_duration} minutes

    Available bots: gtd, llm, dispatcher, synapse, job_applications, learning, terrain, rpg, advocacy, chore, fitness, inbox, notifications, claude_bridge.

    Break this goal into concrete, ordered subtasks. Each should:
    1. Be routable to one of the available bots
    2. Be completable in 5-10 minutes
    3. Have clear success/failure criteria
    4. Have clear dependencies if any

    Return JSON array (and ONLY JSON, no markdown, no code blocks):
    [
      {
        "order": 1,
        "description": "Detailed description of what needs to happen",
        "target_bot": "bot_army_gtd",
        "target_subject": "gtd.task.create",
        "payload": {
          "title": "...",
          "description": "...",
          "due_date": "ISO8601 or null"
        },
        "depends_on": [],
        "needs_verification": true
      }
    ]
    """
  end

  @doc """
  Returns the system prompt for LLM decomposition.

  Sets the behavior and tone for the LLM when decomposing goals.

  ## Returns
    - System prompt string
  """
  def system_prompt do
    """
    You are a task decomposition expert. Your job is to break high-level goals
    into concrete, executable subtasks that can be routed to specialized bots.

    Be precise, concise, and realistic about what can be accomplished in each step.
    Each subtask should be self-contained and achievable within 5-10 minutes.

    Always respond with valid JSON only—no markdown, no explanation, no code blocks.
    """
  end

  @doc """
  Parses LLM response into validated subtasks.

  Extracts JSON from the response and validates each subtask has required fields.

  ## Arguments
    - `response` - NATS reply response (map with "data" key)

  ## Returns
    - `{:ok, subtasks}` - List of validated subtask maps
    - `{:error, reason}` - Error tuple
  """
  def parse_subtasks(response) when is_map(response) do
    # Response from LLM likely has a "data" field wrapping the content
    content = extract_response_content(response)

    case decode_json(content) do
      {:ok, decoded} when is_list(decoded) ->
        validate_subtasks(decoded)

      {:ok, decoded} when is_map(decoded) ->
        # Single object returned, wrap in list
        validate_subtasks([decoded])

      {:error, reason} ->
        Logger.error("[Decomposer] Failed to decode JSON from LLM response", reason: reason)
        {:error, :parse_error}

      :error ->
        Logger.error("[Decomposer] Response content not valid JSON")
        {:error, :parse_error}
    end
  end

  def parse_subtasks(_response) do
    {:error, :invalid_response_format}
  end

  @doc """
  Validates subtask structure.

  Ensures a subtask has all required fields for execution.

  ## Arguments
    - `subtask` - Subtask map to validate

  ## Returns
    - `:ok` if valid
    - `{:error, reason}` if missing required fields
  """
  def validate_subtask_structure(subtask) when is_map(subtask) do
    required_fields = [:order, :description, :target_bot, :target_subject, :payload]

    case Enum.find(required_fields, fn field ->
           not Map.has_key?(subtask, field) and not Map.has_key?(subtask, Atom.to_string(field))
         end) do
      nil ->
        :ok

      missing_field ->
        {:error, {:missing_field, missing_field}}
    end
  end

  def validate_subtask_structure(_), do: {:error, :not_a_map}

  # =====================================================================
  # Private Helpers
  # =====================================================================

  defp call_llm(goal, context, constraints) do
    timeout_ms = @default_timeout_ms

    prompt = build_decomposition_prompt(goal, context, constraints)
    system = system_prompt()

    payload = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "system" => system
    }

    Logger.debug("[Decomposer] Calling LLM service",
      subject: "bot_army_llm.converse",
      timeout_ms: timeout_ms
    )

    case BotArmyRuntime.NATS.Publisher.request(
           "bot_army_llm.converse",
           payload,
           timeout_ms: timeout_ms
         ) do
      {:ok, response} ->
        {:ok, response}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_response_content(response) when is_map(response) do
    # LLM response typically wraps content in "data" field per Reply.ok() pattern
    # But also be defensive for direct string responses
    case response do
      %{"data" => data} when is_binary(data) -> data
      %{"data" => data} when is_map(data) -> Jason.encode!(data)
      %{"content" => content} when is_binary(content) -> content
      _ when is_binary(response) -> response
      _ -> inspect(response)
    end
  end

  defp decode_json(content) when is_binary(content) do
    # Try to extract JSON from the response, handling markdown code blocks if present
    cleaned = clean_json_string(content)

    case Jason.decode(cleaned) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :error
    end
  end

  defp decode_json(_), do: :error

  defp clean_json_string(str) when is_binary(str) do
    # Remove markdown code blocks if present
    str
    |> String.replace(~r/```json\s*/, "")
    |> String.replace(~r/```\s*/, "")
    |> String.trim()
  end

  defp validate_subtasks(subtasks) when is_list(subtasks) do
    case Enum.reduce_while(subtasks, [], fn subtask, acc ->
           case validate_subtask_structure(subtask) do
             :ok -> {:cont, [subtask | acc]}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      {:error, reason} ->
        Logger.error("[Decomposer] Invalid subtask structure", reason: reason)
        {:error, :invalid_structure}

      valid_subtasks ->
        # Sort by order field
        sorted =
          valid_subtasks
          |> Enum.reverse()
          |> Enum.sort_by(fn st ->
            order_key = st[:order] || st["order"]

            case order_key do
              val when is_integer(val) -> val
              _ -> 999
            end
          end)

        {:ok, sorted}
    end
  end

  defp validate_subtasks(_), do: {:error, :invalid_subtasks_format}
end

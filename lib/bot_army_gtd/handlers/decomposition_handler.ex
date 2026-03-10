defmodule BotArmyGtd.Handlers.DecompositionHandler do
  @moduledoc """
  Handles task decomposition via multi-step LLM inference.

  This handler processes decomposition requests, orchestrating a multi-step
  LLM chain that breaks complex tasks into subtasks with effort estimates
  and dependencies. Results are stored in DecompositionStore and can later
  create subtasks in TaskStore.

  Processes incoming messages:
  - `gtd.task.decompose` - Request task decomposition
  - `llm.chain.completed` - Receive multi-step LLM results

  Dependencies:
  - BotArmyGtd.TaskStore
  - BotArmyGtd.DecompositionStore
  - BotArmyGtd.NATS.Publisher
  """

  require Logger

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  defp decomposition_store do
    Application.get_env(:bot_army_gtd, :decomposition_store, BotArmyGtd.DecompositionStore)
  end

  @doc """
  Handle task decomposition request.

  Validates the request, builds a multi-step LLM chain, and publishes
  the inference request to the LLM bot.

  Returns `:ok` if successful.
  """
  def handle_decompose(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_decompose_payload(payload) do
      :ok ->
        process_decompose_request(payload, event_id, message)

      {:error, reason} ->
        Logger.warning("Invalid decomposition payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid decomposition request")
    end
  end

  @doc """
  Handle chain completion response from LLM bot.

  Receives the completed multi-step chain results, parses them, stores the
  decomposition, and publishes completion event.

  Returns `:ok` if successful.
  """
  def handle_chain_completed(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_chain_completed_payload(payload) do
      :ok ->
        process_chain_completed(payload, event_id, message)

      {:error, reason} ->
        Logger.warning("Invalid chain completed payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid chain completion")
    end
  end

  # Private validation

  defp validate_decompose_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "task_id") do
      :ok
    end
  end

  defp validate_decompose_payload(_), do: {:error, :invalid_payload}

  defp validate_chain_completed_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "chain_id"),
         :ok <- require_field(payload, "steps") do
      case payload do
        %{"steps" => steps} when is_list(steps) and length(steps) > 0 -> :ok
        _ -> {:error, :steps_invalid}
      end
    end
  end

  defp validate_chain_completed_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  # Private processing

  defp process_decompose_request(payload, event_id, _message) do
    task_id = payload["task_id"]
    model = Map.get(payload, "model", "claude-opus-4-6")
    chain_id = Map.get(payload, "chain_id", UUID.uuid4())

    # Fetch task from store to get title and context
    case task_store().get(task_id) do
      {:ok, task} ->
        title = task["title"]
        description = Map.get(task, "description", "")

        # Build the multi-step decomposition chain
        steps = build_decomposition_chain(title, description)

        # Request LLM bot to run the inference chain
        publish_chain_request(chain_id, steps, model, task_id, event_id)

      {:error, :not_found} ->
        Logger.warning("Task not found for decomposition: #{task_id}")
        publish_error(event_id, :task_not_found, "Task not found for decomposition")
    end
  end

  defp process_chain_completed(payload, event_id, _message) do
    _chain_id = payload["chain_id"]
    steps = payload["steps"]
    metadata = payload["metadata"] || %{}
    task_id = metadata["task_id"]

    # Parse step outputs
    case parse_decomposition_steps(steps) do
      {:ok, parsed} ->
        # Create decomposition record
        decomposition_payload = %{
          "parent_task_id" => task_id,
          "status" => "completed",
          "step_outputs" => steps,
          "subtask_list" => parsed["subtasks"],
          "effort_estimates" => parsed["effort"],
          "dependencies" => parsed["dependencies"],
          "predicted_subtask_count" => length(parsed["subtasks"] || []),
          "predicted_total_effort_hours" => parsed["total_hours"]
        }

        case decomposition_store().create(decomposition_payload) do
          {:ok, decomposition} ->
            Logger.info("Decomposition created: decomposition_id=#{decomposition["id"]}, task_id=#{task_id}")
            publish_decomposition_completed(decomposition, event_id)

          {:error, reason} ->
            Logger.error("Failed to create decomposition: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to store decomposition")
        end

      {:error, reason} ->
        Logger.error("Failed to parse decomposition steps: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to parse decomposition results")
    end
  end

  # Private helpers

  defp build_decomposition_chain(task_title, description) do
    [
      %{
        "name" => "break_down",
        "prompt" => """
        Task: #{task_title}
        #{if description != "", do: "Description: #{description}", else: ""}

        Break this task into 3-5 subtasks. For each subtask, provide:
        - A clear, specific title
        - One-sentence description
        - Estimated effort in hours (1-8)

        Return a JSON array of subtasks with keys: title, description, estimated_hours
        """
      },
      %{
        "name" => "estimate_effort",
        "prompt" => """
        Based on these subtasks from the previous step:
        {input}

        For each subtask, estimate the effort hours (1-8). Also estimate total project hours.
        Consider complexity, dependencies, and unknowns.

        Return JSON with keys: subtasks (array with title and estimated_hours), total_hours
        """
      },
      %{
        "name" => "identify_dependencies",
        "prompt" => """
        Given these subtasks:
        {input}

        Identify task dependencies. Which subtasks depend on others?
        Return JSON with keys: dependencies (array of {depends_on: "task A", required_for: "task B"})
        """
      }
    ]
  end

  defp parse_decomposition_steps(steps) when is_list(steps) do
    try do
      # Steps should be in order: break_down, estimate_effort, identify_dependencies
      case steps do
        [step1, step2, step3] ->
          # Parse each step's output as JSON
          subtasks = parse_json_field(step1, "subtasks") || []
          effort_data = parse_json_field(step2, "subtasks") || []
          deps_data = parse_json_field(step3, "dependencies") || []
          total_hours = parse_total_hours(step2) || sum_effort(effort_data)

          {:ok, %{
            "subtasks" => subtasks,
            "effort" => effort_data,
            "dependencies" => deps_data,
            "total_hours" => total_hours
          }}

        _ ->
          {:error, :invalid_step_count}
      end
    rescue
      e ->
        Logger.error("Error parsing decomposition steps: #{inspect(e)}")
        {:error, :parse_error}
    end
  end

  defp parse_json_field(step, field_name) do
    case step do
      %{"output" => output} when is_binary(output) ->
        try do
          case Jason.decode(output) do
            {:ok, data} -> Map.get(data, field_name)
            _ -> nil
          end
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_total_hours(step) do
    case step do
      %{"output" => output} when is_binary(output) ->
        try do
          case Jason.decode(output) do
            {:ok, %{"total_hours" => hours}} when is_number(hours) -> hours
            _ -> nil
          end
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp sum_effort(subtasks) when is_list(subtasks) do
    subtasks
    |> Enum.reduce(0.0, fn subtask, acc ->
      hours = Map.get(subtask, "estimated_hours", 0)
      acc + (if is_number(hours), do: hours, else: 0)
    end)
  end

  defp sum_effort(_), do: 0.0

  defp publish_chain_request(chain_id, steps, model, task_id, event_id) do
    event_data = %{
      "event" => "llm.inference.chain",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "chain_id" => chain_id,
        "steps" => steps,
        "model" => model,
        "metadata" => %{
          "task_id" => task_id,
          "source" => "task_decomposition"
        },
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("llm.inference.chain", event_data) do
      {:ok, _subject} -> Logger.debug("Published decomposition chain request to LLM bot")
      {:error, reason} -> Logger.error("Failed to publish chain request: #{inspect(reason)}")
    end
  end

  defp publish_decomposition_completed(decomposition, event_id) do
    event_data = %{
      "event" => "gtd.decomposition.completed",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "decomposition" => decomposition,
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published decomposition.completed event")
      {:error, reason} -> Logger.error("Failed to publish decomposition event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message) do
    error_event = %{
      "event" => "gtd.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(error_event) do
      {:ok, _subject} -> Logger.debug("Published error event from decomposition handler")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end

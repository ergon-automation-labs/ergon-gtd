defmodule BotArmyGtd.Decomposition.Orchestrator do
  @moduledoc """
  Coordinates the multi-step LLM decomposition process and integration
  with external orchestrators.
  """

  require Logger
  alias BotArmyGtd.Decomposition.Registry
  alias BotArmyGtd.EventBuilder
  alias BotArmyLibraryRuntime.NATS.Publisher

  @doc """
  Initiate a decomposition request.
  """
  def request_decomposition(task, model, chain_id, event_id) do
    title = task["title"]
    description = Map.get(task, "description", "")
    
    # Use the Registry module to get capabilities
    registry_snapshot = Registry.get_relevant_capabilities("#{title} #{description}")

    steps = build_decomposition_chain(title, description, registry_snapshot)
    initial_input = "#{title}\n#{if description != "", do: description, else: ""}"

    event_data =
      EventBuilder.build_event("llm.inference.chain", %{
        "chain_id" => chain_id,
        "steps" => steps,
        "initial_input" => initial_input,
        "model" => model,
        "metadata" => %{
          "task_id" => task["id"],
          "source" => "task_decomposition",
          "registry_snapshot" => registry_snapshot
        },
        "triggered_by_event_id" => event_id
      })

    case Publisher.publish("llm.inference.chain", event_data) do
      {:ok, _subject} ->
        Logger.debug("Published decomposition chain request to LLM bot")
        :ok

      {:error, reason} ->
        Logger.error("Failed to publish chain request: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Parse the results of a completed LLM chain.
  """
  def parse_chain_results(steps) when is_list(steps) do
    case steps do
      [step1, step2, step3] ->
        subtasks = parse_json_field(step1, "subtasks") || []
        effort_data = parse_json_field(step2, "subtasks") || []
        deps_data = parse_json_field(step3, "dependencies") || []
        total_hours = parse_total_hours(step2) || sum_effort(effort_data)

        {:ok,
         %{
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

  defp parse_json_field(step, field_name) do
    case step do
      %{"output" => output} when is_binary(output) ->
        case Jason.decode(output) do
          {:ok, data} -> Map.get(data, field_name)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ ->
      nil
  end

  defp parse_total_hours(step) do
    case step do
      %{"output" => output} when is_binary(output) ->
        case Jason.decode(output) do
          {:ok, %{"total_hours" => hours}} when is_number(hours) -> hours
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ ->
      nil
  end

  defp sum_effort(subtasks) when is_list(subtasks) do
    subtasks
    |> Enum.reduce(0.0, fn subtask, acc ->
      hours = Map.get(subtask, "estimated_hours", 0)
      acc + if is_number(hours), do: hours, else: 0
    end)
  end

  defp sum_effort(_), do: 0.0

  defp build_decomposition_chain(task_title, description, registry_context) do
    ctx = if registry_context == "", do: "No live registry snapshot available.", else: registry_context

    [
      %{
        "name" => "break_down",
        "prompt" => """
        Task: #{task_title}
        #{if description != "", do: "Description: #{description}", else: ""}

        Live capability snapshot (from bot registry):
        #{ctx}

        Prefer subtasks that map to existing capabilities above. If a needed
        capability is missing, explicitly mark it as a dependency/risk.

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
end

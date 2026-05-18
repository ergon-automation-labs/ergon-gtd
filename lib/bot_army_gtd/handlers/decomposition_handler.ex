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
  alias BotArmyCore.{NATS, Tenant}
  alias BotArmyGtd.{DecompositionStore, EventBuilder, Handlers.TaskHandler}

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
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_decompose_payload(payload) do
      :ok ->
        process_decompose_request(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid decomposition payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid decomposition request", tenant_id, user_id)
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
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_chain_completed_payload(payload) do
      :ok ->
        process_chain_completed(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid chain completed payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid chain completion", tenant_id, user_id)
    end
  end

  @doc """
  Handle decomposition approval - creates subtasks from approved decomposition.

  Validates the request, fetches the decomposition, creates subtasks in
  TaskStore for each item in subtask_list, and publishes completion event.

  Returns `:ok` if successful.
  """
  def handle_approve(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_approve_payload(payload) do
      :ok ->
        process_approve(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid approval payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid decomposition approval", tenant_id, user_id)
    end
  end

  @doc """
  Handle decomposition rejection - marks as reviewed with grade 0.

  Validates the request, fetches the decomposition, updates status to "reviewed"
  and sets last_grade to 0 (FSRS "again" grade).

  Returns `:ok` if successful.
  """
  def handle_reject(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_reject_payload(payload) do
      :ok ->
        process_reject(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid rejection payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid decomposition rejection", tenant_id, user_id)
    end
  end

  @doc """
  Handle decomposition review with user rating and feedback.

  Validates the request, fetches the decomposition, calculates FSRS grade
  based on user rating and accuracy delta, and publishes reviewed event.

  Returns `:ok` if successful.
  """
  def handle_review(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_review_payload(payload) do
      :ok ->
        process_review(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid review payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid decomposition review", tenant_id, user_id)
    end
  end

  @doc """
  Handle decomposition review request - checks if decomposition is due for review.

  Validates the decomposition exists, checks if it's ready for review (status="completed"
  and due_at <= now), and publishes ready_for_review event with decomposition data.

  This allows the TUI/frontend to trigger review discovery on-demand.

  Returns `:ok` if successful.
  """
  def handle_request_review(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_request_review_payload(payload) do
      :ok ->
        process_request_review(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid review request payload: #{inspect(reason)}")

        publish_error(
          event_id,
          reason,
          "Invalid decomposition review request",
          tenant_id,
          user_id
        )
    end
  end

  # Private validation

  defp validate_decompose_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_decompose_payload(_), do: {:error, :invalid_payload}

  defp validate_chain_completed_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "chain_id"),
         :ok <- require_field(payload, "steps") do
      validate_steps_list(payload)
    end
  end

  defp validate_chain_completed_payload(_), do: {:error, :invalid_payload}

  defp validate_approve_payload(payload) when is_map(payload) do
    require_field(payload, "decomposition_id")
  end

  defp validate_approve_payload(_), do: {:error, :invalid_payload}

  defp validate_reject_payload(payload) when is_map(payload) do
    require_field(payload, "decomposition_id")
  end

  defp validate_reject_payload(_), do: {:error, :invalid_payload}

  defp validate_review_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "decomposition_id"),
         :ok <- require_field(payload, "rating") do
      validate_rating(payload)
    end
  end

  defp validate_review_payload(_), do: {:error, :invalid_payload}

  defp validate_request_review_payload(payload) when is_map(payload) do
    require_field(payload, "decomposition_id")
  end

  defp validate_request_review_payload(_), do: {:error, :invalid_payload}

  defp validate_steps_list(payload) do
    case payload do
      %{"steps" => steps} when is_list(steps) and steps != [] -> :ok
      _ -> {:error, :steps_invalid}
    end
  end

  defp validate_rating(payload) do
    case payload do
      %{"rating" => rating} when is_integer(rating) and rating >= 1 and rating <= 5 -> :ok
      _ -> {:error, :invalid_rating}
    end
  end

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  # Private processing

  defp process_decompose_request(payload, event_id, _message, tenant_id, user_id) do
    task_id = payload["task_id"]
    model = Map.get(payload, "model", "claude-opus-4-6")
    chain_id = Map.get(payload, "chain_id", UUID.uuid4())

    # Fetch task from store to get title and context
    case task_store().get(tenant_id, task_id) do
      {:ok, task} ->
        title = task["title"]
        description = Map.get(task, "description", "")
        registry_snapshot = get_registry_snapshot(title, description)

        # Build the multi-step decomposition chain
        steps = build_decomposition_chain(title, description, registry_snapshot)
        initial_input = "#{title}\n#{if description != "", do: description, else: ""}"

        # Request LLM bot to run the inference chain
        publish_chain_request(
          chain_id,
          steps,
          initial_input,
          model,
          task_id,
          event_id,
          registry_snapshot
        )

      {:error, :not_found} ->
        Logger.warning("Task not found for decomposition: #{task_id}")

        publish_error(
          event_id,
          :task_not_found,
          "Task not found for decomposition",
          tenant_id,
          user_id
        )
    end
  end

  defp process_chain_completed(payload, event_id, _message, tenant_id, user_id) do
    _chain_id = payload["chain_id"]
    steps = payload["steps"]
    metadata = payload["metadata"] || %{}
    task_id = metadata["task_id"]

    # Parse step outputs
    case parse_decomposition_steps(steps) do
      {:ok, parsed} ->
        # Initialize FSRS schedule for new decomposition
        {initial_stability, initial_difficulty, initial_due_at} =
          BotArmyGtd.FSRSScheduler.initial_schedule()

        # Create decomposition record with FSRS fields
        decomposition_payload = %{
          "tenant_id" => tenant_id,
          "user_id" => user_id,
          "parent_task_id" => task_id,
          "status" => "completed",
          "step_outputs" => steps,
          "subtask_list" => parsed["subtasks"],
          "effort_estimates" => parsed["effort"],
          "dependencies" => parsed["dependencies"],
          "predicted_subtask_count" => length(parsed["subtasks"] || []),
          "predicted_total_effort_hours" => parsed["total_hours"],
          "stability" => initial_stability,
          "difficulty" => initial_difficulty,
          "due_at" => initial_due_at,
          "review_count" => 0,
          "decomposition_timestamp" => DateTime.utc_now()
        }

        case decomposition_store().create(decomposition_payload) do
          {:ok, decomposition} ->
            Logger.info(
              "Decomposition created: decomposition_id=#{decomposition["id"]}, task_id=#{task_id}, first review in #{BotArmyGtd.FSRSScheduler.format_interval(initial_due_at)}"
            )

            publish_decomposition_completed(decomposition, event_id, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to create decomposition: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to store decomposition", tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.error("Failed to parse decomposition steps: #{inspect(reason)}")

        publish_error(
          event_id,
          reason,
          "Failed to parse decomposition results",
          tenant_id,
          user_id
        )
    end
  end

  defp process_approve(payload, event_id, _message, tenant_id, user_id) do
    decomposition_id = payload["decomposition_id"]

    case decomposition_store().get(tenant_id, decomposition_id) do
      {:ok, decomposition} ->
        parent_task_id = decomposition["parent_task_id"]
        subtask_list = get_subtask_list(decomposition)

        # Phase 2: Try to execute via Orchestrator if we have routing-capable subtasks
        try_orchestrator_execution(
          decomposition,
          decomposition_id,
          subtask_list,
          parent_task_id,
          tenant_id,
          user_id,
          event_id
        )

      {:error, :not_found} ->
        Logger.warning("Decomposition not found for approval: #{decomposition_id}")
        publish_error(event_id, :not_found, "Decomposition not found")
    end
  end

  defp try_orchestrator_execution(
         decomposition,
         decomposition_id,
         subtask_list,
         parent_task_id,
         tenant_id,
         user_id,
         event_id
       ) do
    # Try to get the parent task title for pattern learning
    parent_task_goal =
      case task_store().get(tenant_id, parent_task_id) do
        {:ok, task} -> Map.get(task, "title", "unknown task")
        {:error, _} -> "unknown task"
      end

    # Try Decomposer to see if we have a high-confidence template match
    case try_decomposer(parent_task_goal) do
      {:ok, decomposer_subtasks} ->
        # Use orchestrator for deterministic template
        Logger.info("[DecompositionHandler] Using Decomposer template for orchestration",
          decomposition_id: decomposition_id,
          goal: String.slice(parent_task_goal, 0, 50)
        )

        orchestrator_outcome =
          BotArmyDispatcher.Orchestrator.execute(decomposer_subtasks,
            decomposition_id: decomposition_id
          )

        # Record success pattern in Learning for future reuse
        case orchestrator_outcome do
          {:ok, outcome} ->
            BotArmyDispatcher.Learning.record_success(
              parent_task_goal,
              decomposer_subtasks,
              %{
                success_rate: outcome["success_rate"],
                execution_time_ms: outcome["execution_time_ms"]
              }
            )

          {:error, _} ->
            nil
        end

        # Still create GTD tasks for tracking/visibility
        created_subtasks =
          create_decomposition_subtasks(subtask_list, parent_task_id, tenant_id, user_id)

        finalize_approval_with_subtasks(
          decomposition,
          decomposition_id,
          subtask_list,
          created_subtasks,
          event_id
        )

      :no_match ->
        # Fall back to traditional LLM chain + GTD task creation
        Logger.debug("[DecompositionHandler] No Decomposer template match, using LLM subtasks",
          decomposition_id: decomposition_id
        )

        created_subtasks =
          create_decomposition_subtasks(subtask_list, parent_task_id, tenant_id, user_id)

        finalize_approval_with_subtasks(
          decomposition,
          decomposition_id,
          subtask_list,
          created_subtasks,
          event_id
        )
    end
  end

  defp try_decomposer(goal) do
    case BotArmyGtd.Decomposer.decompose_goal(goal) do
      {:ok, subtasks} -> {:ok, subtasks}
      {:error, _} -> :no_match
    end
  rescue
    _ -> :no_match
  end

  defp finalize_approval_with_subtasks(
         decomposition,
         decomposition_id,
         subtask_list,
         created_subtasks,
         event_id
       ) do
    successful_tasks = extract_successful_tasks(created_subtasks)
    successful_count = length(successful_tasks)

    actual_total_effort_hours = calculate_actual_effort(subtask_list, created_subtasks)

    {missing_subtasks, extra_subtasks} =
      identify_subtask_differences(subtask_list, successful_tasks)

    fsrs_grade =
      grade_decomposition_accuracy(decomposition, successful_count, actual_total_effort_hours)

    {new_stability, new_difficulty, new_due_at} =
      BotArmyGtd.FSRSScheduler.schedule_next_review(decomposition, fsrs_grade)

    review_result = %{
      decomposition_id: decomposition_id,
      decomposition: decomposition,
      successful_count: successful_count,
      actual_total_effort_hours: actual_total_effort_hours,
      missing_subtasks: missing_subtasks,
      extra_subtasks: extra_subtasks,
      fsrs_grade: fsrs_grade,
      new_stability: new_stability,
      new_difficulty: new_difficulty,
      new_due_at: new_due_at,
      event_id: event_id
    }

    finalize_approved_decomposition(review_result)
  end

  defp create_decomposition_subtasks(subtask_list, parent_task_id, tenant_id, user_id) do
    Enum.map(subtask_list, fn subtask ->
      subtask_payload = %{
        "title" => subtask["title"],
        "description" => subtask["description"],
        "parent_task_id" => parent_task_id,
        "status" => "inbox",
        "estimated_hours" => subtask["estimated_hours"]
      }

      create_event =
        EventBuilder.build_event("gtd.task.create", subtask_payload,
          tenant_id: tenant_id,
          user_id: user_id
        )

      case TaskHandler.handle_create(create_event) do
        {:ok, task} ->
          {:ok, task}

        {:error, reason} ->
          Logger.warning("Failed to create subtask: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  defp extract_successful_tasks(created_subtasks) do
    Enum.flat_map(created_subtasks, fn
      {:ok, task} -> [task]
      _ -> []
    end)
  end

  defp calculate_actual_effort(subtask_list, created_subtasks) do
    Enum.zip(subtask_list, created_subtasks)
    |> Enum.reduce(0.0, fn {subtask, result}, acc ->
      case result do
        {:ok, _} ->
          hours = Map.get(subtask, "estimated_hours") || Map.get(subtask, :estimated_hours, 0)
          acc + normalize_effort_hours(hours)

        _ ->
          acc
      end
    end)
  end

  defp normalize_effort_hours(hours) when is_number(hours), do: hours
  defp normalize_effort_hours(_), do: 0

  defp identify_subtask_differences(subtask_list, successful_tasks) do
    predicted_titles = Enum.map(subtask_list, &Map.get(&1, "title"))

    actual_titles =
      Enum.map(successful_tasks, fn task ->
        Map.get(task, "title") || Map.get(task, :title, "")
      end)

    missing_subtasks = predicted_titles -- actual_titles
    extra_subtasks = actual_titles -- predicted_titles

    {missing_subtasks, extra_subtasks}
  end

  defp grade_decomposition_accuracy(decomposition, successful_count, actual_total_effort_hours) do
    predicted_count = decomposition["predicted_subtask_count"]
    predicted_hours = decomposition["predicted_total_effort_hours"]

    count_delta = calculate_accuracy_delta(predicted_count, successful_count)
    effort_delta = calculate_accuracy_delta(predicted_hours, actual_total_effort_hours)
    combined_delta = max(count_delta, effort_delta)

    calculate_approval_grade(predicted_count, successful_count, combined_delta)
  end

  defp finalize_approved_decomposition(review_result) do
    %{
      decomposition_id: decomposition_id,
      decomposition: decomposition,
      successful_count: successful_count,
      actual_total_effort_hours: actual_total_effort_hours,
      missing_subtasks: missing_subtasks,
      extra_subtasks: extra_subtasks,
      fsrs_grade: fsrs_grade,
      new_stability: new_stability,
      new_difficulty: new_difficulty,
      new_due_at: new_due_at,
      event_id: event_id
    } = review_result

    updated_decomposition =
      decomposition
      |> Map.put("actual_subtask_count", successful_count)
      |> Map.put("actual_total_effort_hours", actual_total_effort_hours)
      |> Map.put("missing_subtasks", missing_subtasks)
      |> Map.put("extra_subtasks", extra_subtasks)
      |> Map.put("status", "reviewed")
      |> Map.put("last_grade", fsrs_grade)
      |> Map.put("stability", new_stability)
      |> Map.put("difficulty", new_difficulty)
      |> Map.put("due_at", new_due_at)
      |> Map.put("review_count", (decomposition["review_count"] || 0) + 1)

    case decomposition_store().update(decomposition_id, updated_decomposition) do
      {:ok, updated} ->
        Logger.info("Decomposition approved", %{
          decomposition_id: decomposition_id,
          parent_task_id: decomposition["parent_task_id"],
          subtasks_created: successful_count,
          fsrs_grade: fsrs_grade,
          next_review_in: BotArmyGtd.FSRSScheduler.format_interval(new_due_at),
          review_count: (decomposition["review_count"] || 0) + 1
        })

        publish_decomposition_approved(updated, event_id)

      {:error, reason} ->
        Logger.error("Failed to update decomposition: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to update decomposition after approval")
    end
  end

  defp process_reject(payload, event_id, _message, tenant_id, _user_id) do
    decomposition_id = payload["decomposition_id"]

    case decomposition_store().get(tenant_id, decomposition_id) do
      {:ok, decomposition} ->
        # Use FSRS grade 1 (again) for rejection
        {new_stability, new_difficulty, new_due_at} =
          BotArmyGtd.FSRSScheduler.schedule_next_review(decomposition, 1)

        # Update with FSRS parameters and status="reviewed"
        updated_decomposition =
          decomposition
          |> Map.put("last_grade", 1)
          |> Map.put("status", "reviewed")
          |> Map.put("stability", new_stability)
          |> Map.put("difficulty", new_difficulty)
          |> Map.put("due_at", new_due_at)
          |> Map.put("review_count", (decomposition["review_count"] || 0) + 1)

        case decomposition_store().update(decomposition_id, updated_decomposition) do
          {:ok, updated} ->
            Logger.info(
              "Decomposition rejected: decomposition_id=#{decomposition_id}, next review in #{BotArmyGtd.FSRSScheduler.format_interval(new_due_at)}"
            )

            publish_decomposition_reviewed(updated, event_id)

          {:error, reason} ->
            Logger.error("Failed to update decomposition on rejection: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to update decomposition on rejection")
        end

      {:error, :not_found} ->
        Logger.warning("Decomposition not found for rejection: #{decomposition_id}")
        publish_error(event_id, :not_found, "Decomposition not found")
    end
  end

  defp process_review(payload, event_id, _message, tenant_id, _user_id) do
    decomposition_id = payload["decomposition_id"]
    rating = payload["rating"]
    user_feedback = Map.get(payload, "feedback", "")

    case decomposition_store().get(tenant_id, decomposition_id) do
      {:ok, decomposition} ->
        predicted_count = decomposition["predicted_subtask_count"]
        actual_count = decomposition["actual_subtask_count"]
        predicted_hours = decomposition["predicted_total_effort_hours"]
        actual_hours = decomposition["actual_total_effort_hours"]
        review_count = Map.get(decomposition, "review_count", 0)

        # Calculate accuracy deltas for both count and effort
        count_delta = calculate_accuracy_delta(predicted_count, actual_count)
        effort_delta = calculate_accuracy_delta(predicted_hours, actual_hours)
        combined_delta = max(count_delta, effort_delta)

        # FSRS grade uses combined delta for more robust learning signal
        fsrs_grade = calculate_fsrs_grade(rating, combined_delta)

        # Calculate FSRS next review timing (1-4 grade)
        {new_stability, new_difficulty, new_due_at} =
          BotArmyGtd.FSRSScheduler.schedule_next_review(decomposition, fsrs_grade + 1)

        # Update decomposition with review data and FSRS parameters
        updated_decomposition =
          decomposition
          |> Map.put("user_rating", rating)
          |> Map.put("user_feedback", user_feedback)
          |> Map.put("confidence_grade", combined_delta)
          |> Map.put("last_grade", fsrs_grade)
          |> Map.put("review_count", review_count + 1)
          |> Map.put("stability", new_stability)
          |> Map.put("difficulty", new_difficulty)
          |> Map.put("due_at", new_due_at)
          |> Map.put("status", "reviewed")

        review_update = %{
          decomposition_id: decomposition_id,
          decomposition: decomposition,
          updated_decomposition: updated_decomposition,
          rating: rating,
          fsrs_grade: fsrs_grade,
          count_delta: count_delta,
          effort_delta: effort_delta,
          review_count: review_count,
          new_due_at: new_due_at,
          event_id: event_id
        }

        finalize_review_update(review_update)

      {:error, :not_found} ->
        Logger.warning("Decomposition not found for review: #{decomposition_id}")
        publish_error(event_id, :not_found, "Decomposition not found")
    end
  end

  defp process_request_review(payload, event_id, _message, tenant_id, user_id) do
    decomposition_id = payload["decomposition_id"]

    case decomposition_store().get(tenant_id, decomposition_id) do
      {:ok, decomposition} ->
        status = decomposition["status"]
        due_at_str = decomposition["due_at"]

        # Check if decomposition is ready for review
        is_due = check_if_due(status, due_at_str)

        if is_due do
          Logger.info("Decomposition ready for review", %{
            decomposition_id: decomposition_id,
            parent_task_id: decomposition["parent_task_id"],
            status: status,
            review_count: decomposition["review_count"],
            due_at: due_at_str
          })

          publish_decomposition_ready_for_review(decomposition, event_id, tenant_id, user_id)
        else
          Logger.warning("Decomposition not ready for review", %{
            decomposition_id: decomposition_id,
            parent_task_id: decomposition["parent_task_id"],
            status: status,
            due_at: due_at_str,
            reason: "status or due_at mismatch"
          })

          publish_error(
            event_id,
            :not_ready,
            "Decomposition is not ready for review (status=#{status})",
            tenant_id,
            user_id
          )
        end

      {:error, :not_found} ->
        Logger.warning("Decomposition not found for review request: #{decomposition_id}")
        publish_error(event_id, :not_found, "Decomposition not found", tenant_id, user_id)
    end
  end

  defp finalize_review_update(review_update) do
    %{
      decomposition_id: decomposition_id,
      decomposition: decomposition,
      updated_decomposition: updated_decomposition,
      rating: rating,
      fsrs_grade: fsrs_grade,
      count_delta: count_delta,
      effort_delta: effort_delta,
      review_count: review_count,
      new_due_at: new_due_at,
      event_id: event_id
    } = review_update

    case decomposition_store().update(decomposition_id, updated_decomposition) do
      {:ok, updated} ->
        Logger.info("Decomposition reviewed", %{
          decomposition_id: decomposition_id,
          parent_task_id: decomposition["parent_task_id"],
          user_rating: rating,
          fsrs_grade: fsrs_grade,
          count_delta: count_delta,
          effort_delta: effort_delta,
          review_count: review_count + 1,
          next_review_in: BotArmyGtd.FSRSScheduler.format_interval(new_due_at)
        })

        publish_decomposition_reviewed(updated, event_id)
        publish_accuracy_metrics(updated, count_delta, effort_delta)

        grade_result = if(fsrs_grade >= 2, do: "pass", else: "fail")

        BotArmyLearning.OutcomeTracker.record(
          decomposition_id,
          "decomposition",
          "approved",
          grade_result
        )

      {:error, reason} ->
        Logger.error("Failed to update decomposition on review: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to update decomposition on review")
    end
  end

  # Private helpers

  defp build_decomposition_chain(task_title, description, registry_snapshot) do
    registry_context =
      case registry_snapshot do
        "" -> "No live registry snapshot available."
        text -> text
      end

    [
      %{
        "name" => "break_down",
        "prompt" => """
        Task: #{task_title}
        #{if description != "", do: "Description: #{description}", else: ""}

        Live capability snapshot (from bot registry):
        #{registry_context}

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

  defp parse_decomposition_steps(steps) when is_list(steps) do
    case steps do
      [step1, step2, step3] ->
        # Parse each step's output as JSON
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

  # FSRS and approval helpers

  defp get_subtask_list(decomposition) do
    case decomposition["subtask_list"] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp calculate_accuracy_delta(nil, _), do: 0.0
  defp calculate_accuracy_delta(_, nil), do: 0.0
  defp calculate_accuracy_delta(0, _), do: 0.0

  defp calculate_accuracy_delta(predicted, actual) do
    abs(predicted - actual) / predicted
  end

  defp calculate_fsrs_grade(rating, delta) when rating < 3 or delta > 0.3, do: 0
  defp calculate_fsrs_grade(3, delta) when delta > 0.2, do: 1
  defp calculate_fsrs_grade(4, delta) when delta < 0.2, do: 2
  defp calculate_fsrs_grade(5, delta) when delta < 0.1, do: 3
  defp calculate_fsrs_grade(_, _), do: 2

  defp calculate_approval_grade(predicted, actual, combined_delta \\ 0.0)
  defp calculate_approval_grade(nil, _, _), do: 3
  defp calculate_approval_grade(_, nil, _), do: 3

  defp calculate_approval_grade(predicted, actual, combined_delta) do
    # Grade based on how well actual subtask count and effort match prediction
    # FSRS grades: 1 (Again), 2 (Hard), 3 (Good), 4 (Easy)
    diff = abs(predicted - actual)

    cond do
      # Large effort/count mismatch: "Again"
      combined_delta > 0.5 or diff >= 4 -> 1
      # Moderate mismatch: "Hard"
      combined_delta > 0.2 or diff >= 2 -> 2
      # Perfect or near-perfect match: "Good"
      diff == 0 -> 3
      diff == 1 -> 3
      # Fallback
      true -> 2
    end
  end

  defp check_if_due(status, due_at_str) do
    status in ["completed", "reviewed"] and due_at_str && due_now?(due_at_str)
  end

  defp due_now?(due_at_str) when is_binary(due_at_str) do
    case DateTime.from_iso8601(due_at_str) do
      {:ok, due_at, _offset} ->
        now = DateTime.utc_now()
        DateTime.compare(due_at, now) in [:lt, :eq]

      {:error, _} ->
        false
    end
  end

  defp due_now?(_), do: false

  defp publish_chain_request(
         chain_id,
         steps,
         initial_input,
         model,
         task_id,
         event_id,
         registry_snapshot
       ) do
    event_data =
      EventBuilder.build_event("llm.inference.chain", %{
        "chain_id" => chain_id,
        "steps" => steps,
        "initial_input" => initial_input,
        "model" => model,
        "metadata" => %{
          "task_id" => task_id,
          "source" => "task_decomposition",
          "registry_snapshot" => registry_snapshot
        },
        "triggered_by_event_id" => event_id
      })

    case BotArmyRuntime.NATS.Publisher.publish("llm.inference.chain", event_data) do
      {:ok, _subject} -> Logger.debug("Published decomposition chain request to LLM bot")
      {:error, reason} -> Logger.error("Failed to publish chain request: #{inspect(reason)}")
    end
  end

  defp publish_decomposition_completed(decomposition, event_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "gtd.decomposition.completed",
        %{
          "decomposition" => decomposition,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("Published decomposition.completed event")

      {:error, reason} ->
        Logger.error("Failed to publish decomposition event: #{inspect(reason)}")
    end
  end

  defp publish_decomposition_approved(decomposition, event_id) do
    event_data =
      EventBuilder.build_event("gtd.decomposition.approved", %{
        "decomposition" => decomposition,
        "triggered_by_event_id" => event_id
      })

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("Published decomposition.approved event")

      {:error, reason} ->
        Logger.error("Failed to publish decomposition.approved event: #{inspect(reason)}")
    end
  end

  defp publish_decomposition_reviewed(decomposition, event_id) do
    event_data =
      EventBuilder.build_event("gtd.decomposition.reviewed", %{
        "decomposition" => decomposition,
        "triggered_by_event_id" => event_id
      })

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("Published decomposition.reviewed event")

      {:error, reason} ->
        Logger.error("Failed to publish decomposition.reviewed event: #{inspect(reason)}")
    end
  end

  defp publish_decomposition_ready_for_review(decomposition, event_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "gtd.decomposition.ready_for_review",
        %{
          "decomposition" => decomposition,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("Published decomposition.ready_for_review event")

      {:error, reason} ->
        Logger.error("Failed to publish ready_for_review event: #{inspect(reason)}")
    end
  end

  defp publish_accuracy_metrics(decomposition, count_delta, effort_delta) do
    event = %{
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "schema_version" => "1.0",
      "event" => "gtd.decomposition.accuracy",
      "tenant_id" => decomposition["tenant_id"] || Tenant.default_tenant_id(),
      "payload" => %{
        "decomposition_id" => decomposition["id"],
        "parent_task_id" => decomposition["parent_task_id"],
        "predicted_subtask_count" => decomposition["predicted_subtask_count"],
        "actual_subtask_count" => decomposition["actual_subtask_count"],
        "predicted_total_effort_hours" => decomposition["predicted_total_effort_hours"],
        "actual_total_effort_hours" => decomposition["actual_total_effort_hours"],
        "count_delta" => count_delta,
        "effort_delta" => effort_delta,
        "user_rating" => decomposition["user_rating"],
        "review_count" => decomposition["review_count"],
        "missing_subtasks" => length(decomposition["missing_subtasks"] || []),
        "extra_subtasks" => length(decomposition["extra_subtasks"] || [])
      }
    }

    case NATS.publish("bot_army.gtd.decomposition.accuracy", event) do
      {:ok, _} ->
        Logger.info(
          "[DecompositionHandler] Published accuracy metrics for #{decomposition["id"]}"
        )

      {:error, reason} ->
        Logger.warning(
          "[DecompositionHandler] Failed to publish accuracy metrics: #{inspect(reason)}"
        )
    end
  catch
    _, reason ->
      Logger.warning(
        "[DecompositionHandler] Exception publishing accuracy metrics: #{inspect(reason)}"
      )
  end

  defp publish_error(event_id, reason, message) do
    default_tenant_id = Tenant.default_tenant_id()
    publish_error(event_id, reason, message, default_tenant_id, nil)
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published error event from decomposition handler")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  defp get_registry_snapshot(task_title, description) do
    query_text = "#{task_title} #{description}" |> String.downcase()

    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        request_body = Jason.encode!(%{"include_subjects" => true})

        case Gnat.request(conn, "bot_army.registry.bots.list", request_body,
               receive_timeout: 3_000
             ) do
          {:ok, response} ->
            response.body
            |> Jason.decode()
            |> format_registry_snapshot(query_text)

          {:error, reason} ->
            Logger.debug("Registry snapshot unavailable: #{inspect(reason)}")
            ""
        end

      {:error, reason} ->
        Logger.debug("NATS connection unavailable for registry snapshot: #{inspect(reason)}")
        ""
    end
  end

  defp format_registry_snapshot({:ok, %{"ok" => true, "data" => data}}, query_text) do
    bots =
      case data do
        %{"bots" => list} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> []
      end

    bots
    |> Enum.filter(&registry_bot_relevant?(&1, query_text))
    |> Enum.take(8)
    |> Enum.map(&format_registry_bot/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_registry_snapshot(_decode_result, _query_text), do: ""

  defp registry_bot_relevant?(bot, query_text) do
    text_blob =
      [Map.get(bot, "name", ""), Map.get(bot, "bot_name", ""), Map.get(bot, "description", "")]
      |> Kernel.++(extract_subject_names(bot))
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(String.split(query_text, ~r/\s+/, trim: true), fn token ->
      String.length(token) > 2 and String.contains?(text_blob, token)
    end)
  end

  defp extract_subject_names(bot) do
    case Map.get(bot, "subjects") do
      subjects when is_list(subjects) ->
        Enum.map(subjects, fn
          %{"subject" => subject} -> subject
          subject when is_binary(subject) -> subject
          _ -> ""
        end)

      _ ->
        []
    end
  end

  defp format_registry_bot(bot) do
    name = Map.get(bot, "name") || Map.get(bot, "bot_name") || "unknown_bot"

    subjects =
      bot
      |> extract_subject_names()
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(6)
      |> Enum.join(", ")

    if subjects == "" do
      ""
    else
      "- #{name}: #{subjects}"
    end
  end
end

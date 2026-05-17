defmodule BotArmyGtd.Handlers.TaskHandler do
  @moduledoc """
  Handles task-related events for the GTD bot.

  This module processes incoming task messages:
  - `gtd.task.create` - Create a new task
  - `gtd.task.update` - Update existing task
  - `gtd.task.complete` - Mark task as complete

  Each operation validates the input, performs the action, and publishes
  corresponding response events.

  ## Dependencies

  - `BotArmyGtd.TaskStore` - Persistent task storage
  - `BotArmyGtd.NATS.Publisher` - Event publishing
  """

  require Logger

  alias BotArmyCore.Tenant

  alias BotArmyGtd.{
    Adapters.ConfidenceAdapter,
    Adapters.PlanAdapter,
    EventBuilder,
    NATS.Publisher,
    ParaExporter,
    PlanStore,
    ProjectStore,
    TaskIntakeGuard,
    TaskStore
  }

  @active_until_key "active_until"
  @active_until_window_days 7

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle task creation event.

  Validates the task data, stores it, and publishes a task.created event.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_create(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    TaskIntakeGuard.log_caller_metadata("gtd.task.create", message)

    payload = maybe_stamp_active_until_for_create(payload)

    # Stamp tenant and user context into payload
    stamped_payload =
      Map.merge(payload, %{
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case validate_create_payload(stamped_payload) do
      :ok ->
        if TaskIntakeGuard.suspicious_test_data?(message, stamped_payload) do
          Logger.warning(
            "Rejected suspicious test task create payload: event_id=#{event_id} payload=#{inspect(stamped_payload)}"
          )

          reason = :rejected_suspected_test_data
          publish_error(event_id, reason, "Rejected suspicious test data", tenant_id, user_id)
          {:error, reason}
        else
          create_and_publish_task(stamped_payload, event_id, message, tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.warning("Invalid task creation payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
        {:error, reason}
    end
  end

  defp create_and_publish_task(stamped_payload, event_id, message, tenant_id, user_id) do
    case task_store().create(stamped_payload) do
      {:ok, task} ->
        Logger.info("Task created: task_id=#{task["id"]}, event_id=#{event_id}")

        publish_event(
          "gtd.task.created",
          stamped_payload,
          task,
          event_id,
          message,
          tenant_id,
          user_id
        )

        maybe_trigger_decomposition(task, stamped_payload, tenant_id, user_id)
        maybe_notify_para(task, tenant_id)

        {:ok, task}

      {:error, reason} ->
        Logger.error("Failed to create task: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to create task", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task update event.

  Validates the update data, applies it, and publishes a task.updated event.
  """
  def handle_update(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_update_payload(payload) do
      :ok ->
        task_id = payload["task_id"]
        {old_status, payload} = apply_active_until_and_capture_status(tenant_id, task_id, payload)

        case scoped_update(tenant_id, task_id, payload) do
          {:ok, task} ->
            Logger.info("Task updated: task_id=#{task_id}, event_id=#{event_id}")

            publish_event(
              "gtd.task.updated",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            new_status = task["status"]
            notify_status_change_if_needed(task, old_status, new_status)

            :ok

          {:error, reason} ->
            Logger.error("Failed to update task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to update task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task update payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task completion event.

  Marks the task as complete and publishes a task.completed event.
  """
  def handle_complete(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_complete_payload(payload) do
      :ok ->
        task_id = payload["task_id"]

        case scoped_complete(tenant_id, task_id) do
          {:ok, task} ->
            Logger.info("Task completed: task_id=#{task_id}, event_id=#{event_id}")

            publish_event(
              "gtd.task.completed",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            ParaExporter.notify_completed(task)
            ParaExporter.rotate_next_action(task, tenant_id)

            # Handle plan completion if this task is part of a plan
            maybe_handle_plan_completion(task, tenant_id, user_id)

            # Record outcome: task was completed
            try do
              BotArmyLearning.OutcomeTracker.record(
                task_id,
                "gtd.task_completion",
                "completed",
                "completed",
                true
              )
            rescue
              _ -> :ok
            end

            :ok

          {:error, reason} ->
            Logger.error("Failed to complete task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to complete task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task completion payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task defer event.

  Defers a task to a future date and publishes a task.state.updated event.
  """
  def handle_defer(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_defer_payload(payload) do
      :ok ->
        task_id = payload["task_id"]
        defer_until = payload["defer_until"]

        case scoped_update(tenant_id, task_id, %{"due_date" => defer_until}) do
          {:ok, task} ->
            Logger.info(
              "Task deferred: task_id=#{task_id}, until=#{defer_until}, event_id=#{event_id}"
            )

            publish_event(
              "gtd.task.state.updated",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to defer task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to defer task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task defer payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid defer data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task delete event.

  Marks a task as deleted and publishes a task.state.updated event.
  """
  def handle_delete(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_delete_payload(payload) do
      :ok ->
        task_id = payload["task_id"]

        case scoped_update(tenant_id, task_id, %{"status" => "deleted"}) do
          {:ok, task} ->
            Logger.info("Task deleted: task_id=#{task_id}, event_id=#{event_id}")

            publish_event(
              "gtd.task.state.updated",
              payload,
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to delete task #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to delete task", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task delete payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid delete data", tenant_id, user_id)
        {:error, reason}
    end
  end

  @doc """
  Handle task failure event.

  Marks a task as failed and attempts to replan remaining steps in the plan
  if the task is part of a plan. Falls back to user notification if replan fails.
  """
  def handle_fail(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case validate_fail_payload(payload) do
      :ok ->
        task_id = payload["task_id"]
        failure_reason = payload["failure_reason"] || "Unknown error"

        # Mark task as failed
        case scoped_update(tenant_id, task_id, %{"status" => "failed"}) do
          {:ok, task} ->
            Logger.info(
              "Task failed: task_id=#{task_id}, reason=#{failure_reason}, event_id=#{event_id}"
            )

            publish_event(
              "gtd.task.failed",
              %{"task_id" => task_id, "failure_reason" => failure_reason},
              task,
              event_id,
              message,
              tenant_id,
              user_id
            )

            handle_task_failure_by_plan(task, task_id, failure_reason, tenant_id, user_id)

            :ok

          {:error, reason} ->
            Logger.error("Failed to mark task as failed #{task_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to mark task as failed", tenant_id, user_id)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Invalid task fail payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid failure data", tenant_id, user_id)
        {:error, reason}
    end
  end

  # Private functions

  defp handle_task_failure_by_plan(task, task_id, failure_reason, tenant_id, user_id) do
    plan_id = task["plan_id"]

    if is_binary(plan_id) and plan_id != "" do
      handle_plan_task_failure(task, plan_id, failure_reason, tenant_id, user_id)
    else
      emit_failure_decision_event(:no_plan, 0, task_id, tenant_id, user_id)
    end
  end

  defp notify_status_change_if_needed(task, old_status, new_status) do
    if old_status && new_status && old_status != new_status do
      ParaExporter.notify_status_change(task, old_status, new_status)
    end
  end

  defp validate_create_payload(payload) when is_map(payload) do
    require_field(payload, "title")
  end

  defp validate_create_payload(_), do: {:error, :invalid_payload}

  defp validate_update_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_update_payload(_), do: {:error, :invalid_payload}

  defp validate_complete_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_complete_payload(_), do: {:error, :invalid_payload}

  defp validate_defer_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
    |> then(fn
      :ok -> require_field(payload, "defer_until")
      err -> err
    end)
  end

  defp validate_defer_payload(_), do: {:error, :invalid_payload}

  defp validate_delete_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_delete_payload(_), do: {:error, :invalid_payload}

  defp validate_fail_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_fail_payload(_), do: {:error, :invalid_payload}

  defp attempt_replan(plan_id, task_id, failure_reason, tenant_id, user_id) do
    context = %{
      tenant_id: tenant_id,
      user_id: user_id
    }

    case PlanAdapter.replan_on_failure(
           plan_id,
           task_id,
           failure_reason,
           context
         ) do
      {:ok, new_tasks} ->
        Logger.info(
          "[TaskHandler] Successfully replanned after task failure: plan_id=#{plan_id}, new_task_count=#{length(new_tasks)}"
        )

        emit_adaptation_metric(true, :success)
        :ok

      {:error, :timeout} ->
        Logger.warning(
          "[TaskHandler] Replan timed out for plan_id=#{plan_id}, falling back to notification"
        )

        emit_adaptation_metric(false, :timeout)
        notify_user_of_failure(plan_id, task_id, failure_reason, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning(
          "[TaskHandler] Replan failed for plan_id=#{plan_id}: #{inspect(reason)}, falling back to notification"
        )

        emit_adaptation_metric(false, reason)
        notify_user_of_failure(plan_id, task_id, failure_reason, tenant_id, user_id)
    end
  end

  defp emit_adaptation_metric(success, reason) do
    metric_name =
      if success,
        do: "gtd.plan_adaptation.success",
        else: "gtd.plan_adaptation.failure"

    # Emit to metrics/observability system
    Logger.debug(
      "[TaskHandler] Emitting adaptation metric: #{metric_name}, reason=#{inspect(reason)}"
    )
  rescue
    _ -> :ok
  end

  defp notify_user_of_failure(plan_id, task_id, failure_reason, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "gtd.plan.needs_attention",
        %{
          "plan_id" => plan_id,
          "failed_task_id" => task_id,
          "failure_reason" => failure_reason,
          "message" =>
            "Plan step failed and could not be auto-recovered. Manual intervention needed."
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _} ->
        Logger.info("[TaskHandler] Published plan failure notification for plan_id=#{plan_id}")

      :ok ->
        Logger.info("[TaskHandler] Published plan failure notification for plan_id=#{plan_id}")

      {:error, reason} ->
        Logger.warning("[TaskHandler] Failed to publish failure notification: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[TaskHandler] Error notifying user of failure: #{inspect(e)}")
  end

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp publish_event(event_type, _payload, task, event_id, _original_message, tenant_id, user_id) do
    payload = %{
      "task" => task,
      "triggered_by_event_id" => event_id
    }

    event_data =
      EventBuilder.build_event(
        event_type,
        payload,
        tenant_id: tenant_id,
        user_id: user_id
      )

    # Flatten task metadata to top level for cross-bot consumers (RPG progression, quest auto-create)
    event_data =
      if event_type in ["gtd.task.completed", "gtd.task.created"] do
        event_data
        |> Map.put("priority", Map.get(task, "priority", "normal"))
        |> Map.put("task_id", Map.get(task, "id"))
        |> Map.put("task_title", Map.get(task, "title", ""))
      else
        event_data
      end

    case Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published event: #{event_type}")
      {:error, reason} -> Logger.error("Failed to publish event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  # Use tenant-scoped store calls when available, but keep compatibility with existing mocks.
  defp scoped_update(tenant_id, task_id, payload) do
    store = task_store()

    if function_exported?(store, :update, 3) do
      store.update(tenant_id, task_id, payload)
    else
      store.update(task_id, payload)
    end
  end

  defp scoped_complete(tenant_id, task_id) do
    store = task_store()

    if function_exported?(store, :complete, 2) do
      store.complete(tenant_id, task_id)
    else
      store.complete(task_id)
    end
  end

  defp maybe_trigger_decomposition(task, payload, tenant_id, user_id) do
    if Map.get(payload, "decompose", false) == true do
      decom_payload =
        %{
          "task_id" => task["id"],
          "model" => Map.get(payload, "decompose_model"),
          "chain_id" => Map.get(payload, "decompose_chain_id")
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      decompose_event =
        EventBuilder.build_event("gtd.task.decompose", decom_payload,
          tenant_id: tenant_id,
          user_id: user_id
        )

      case BotArmyRuntime.NATS.Publisher.publish("gtd.task.decompose", decompose_event) do
        {:ok, _} ->
          Logger.info("Triggered decomposition for task_id=#{task["id"]}")

        {:error, reason} ->
          Logger.warning(
            "Task created but failed to trigger decomposition for task_id=#{task["id"]}: #{inspect(reason)}"
          )
      end
    end
  end

  defp maybe_notify_para(task, tenant_id) do
    project_id = task["project_id"]

    if is_binary(project_id) and project_id != "" and project_id != "_inbox" do
      try do
        project_store =
          Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

        case project_store.get(tenant_id, project_id) do
          {:ok, project} ->
            ParaExporter.notify_task_created(task, project["name"])

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end
  end

  def expire_active_tasks(tenant_id, user_id \\ nil) do
    filters = %{"status" => ["active"]}

    case task_store().list(tenant_id, filters) do
      {:ok, tasks} ->
        Enum.each(tasks, &process_expiry_for_task(&1, tenant_id, user_id))

      {:error, reason} ->
        Logger.warning("Failed to list active tasks for expiry: #{inspect(reason)}")
    end
  end

  defp process_expiry_for_task(task, tenant_id, user_id) do
    case parse_active_until(task) do
      {:ok, active_until} ->
        if DateTime.compare(active_until, DateTime.utc_now()) == :lt do
          expire_task(task, tenant_id, user_id)
        end

      :none ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp expire_task(task, tenant_id, user_id) do
    task_id = task["id"]
    description = append_backlog_note(task["description"] || "")
    source_metadata = clear_active_until(task["source_metadata"])

    update_payload = %{
      "status" => "inbox",
      "description" => description,
      "source_metadata" => source_metadata
    }

    case scoped_update(tenant_id, task_id, update_payload) do
      {:ok, updated_task} ->
        publish_event(
          "gtd.task.updated",
          update_payload,
          updated_task,
          UUID.uuid4(),
          %{},
          tenant_id,
          user_id
        )

      {:error, reason} ->
        Logger.warning("Failed to auto-expire task #{task_id}: #{inspect(reason)}")
    end
  end

  defp maybe_stamp_active_until_for_create(payload) when is_map(payload) do
    status = Map.get(payload, "status", "active")

    if status == "active" do
      source_metadata = stamp_active_until(Map.get(payload, "source_metadata"))
      Map.put(payload, "source_metadata", source_metadata)
    else
      payload
    end
  end

  defp apply_active_until_and_capture_status(tenant_id, task_id, payload) do
    case task_store().get(tenant_id, task_id) do
      {:ok, task} ->
        current_status = Map.get(task, "status")
        incoming_status = Map.get(payload, "status")

        updated_payload =
          cond do
            incoming_status == "active" ->
              refresh_payload_active_until(payload, task)

            current_status == "active" ->
              handle_active_task_status(task, payload)

            true ->
              payload
          end

        {current_status, updated_payload}

      {:error, _reason} ->
        {nil, payload}
    end
  end

  defp refresh_payload_active_until(payload, task) do
    source_metadata =
      task
      |> Map.get("source_metadata")
      |> merge_source_metadata(Map.get(payload, "source_metadata"))
      |> stamp_active_until()

    Map.put(payload, "source_metadata", source_metadata)
  end

  defp apply_active_until_status(active_until, payload, task) do
    if DateTime.compare(active_until, DateTime.utc_now()) == :lt do
      demote_payload_to_inbox(payload, task)
    else
      refresh_payload_active_until(payload, task)
    end
  end

  defp handle_active_task_status(task, payload) do
    case parse_active_until(task) do
      {:ok, active_until} ->
        apply_active_until_status(active_until, payload, task)

      _ ->
        refresh_payload_active_until(payload, task)
    end
  end

  defp demote_payload_to_inbox(payload, task) do
    source_metadata =
      task
      |> Map.get("source_metadata")
      |> merge_source_metadata(Map.get(payload, "source_metadata"))
      |> clear_active_until()

    description =
      payload
      |> Map.get("description", task["description"] || "")
      |> append_backlog_note()

    payload
    |> Map.put("status", "inbox")
    |> Map.put("description", description)
    |> Map.put("source_metadata", source_metadata)
  end

  defp merge_source_metadata(existing, incoming) do
    existing_map = if is_map(existing), do: existing, else: %{}
    incoming_map = if is_map(incoming), do: incoming, else: %{}
    Map.merge(existing_map, incoming_map)
  end

  defp stamp_active_until(source_metadata) do
    metadata = if is_map(source_metadata), do: source_metadata, else: %{}

    active_until =
      DateTime.utc_now()
      |> DateTime.add(@active_until_window_days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    Map.put(metadata, @active_until_key, active_until)
  end

  defp clear_active_until(source_metadata) do
    metadata = if is_map(source_metadata), do: source_metadata, else: %{}
    Map.delete(metadata, @active_until_key)
  end

  defp parse_active_until(task) do
    source_metadata = task["source_metadata"]

    with true <- is_map(source_metadata),
         active_until when is_binary(active_until) <- source_metadata[@active_until_key],
         {:ok, dt, _offset} <- DateTime.from_iso8601(active_until) do
      {:ok, dt}
    else
      false -> :none
      nil -> :none
      _ -> {:error, :invalid_active_until}
    end
  end

  defp append_backlog_note(description) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    note =
      "[PUSHED_TO_BACKLOG #{timestamp}] active_until expired; moved to inbox for re-prioritization."

    if String.contains?(description, "active_until expired; moved to inbox") do
      description
    else
      (description <> "\n\n" <> note) |> String.trim()
    end
  end

  defp maybe_handle_plan_completion(task, tenant_id, user_id) do
    plan_id = task["plan_id"]

    if is_binary(plan_id) and plan_id != "" do
      try do
        plan_store =
          Application.get_env(:bot_army_gtd, :plan_store, BotArmyGtd.PlanStore)

        case plan_store.get(tenant_id, plan_id) do
          {:ok, plan} ->
            # Check if all tasks in this plan are now complete
            check_and_complete_plan_if_done(plan, tenant_id, user_id)

          {:error, reason} ->
            Logger.warning("Failed to fetch plan #{plan_id}: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.warning("Error handling plan completion: #{inspect(e)}")
      end
    end
  end

  defp check_and_complete_plan_if_done(plan, tenant_id, user_id) do
    plan_id = plan["id"]
    plan_store = Application.get_env(:bot_army_gtd, :plan_store, BotArmyGtd.PlanStore)
    task_store = task_store()

    case task_store.list_by_plan(tenant_id, plan_id) do
      {:ok, tasks} ->
        incomplete_tasks =
          Enum.reject(tasks, fn t -> t["status"] in ["completed", "deleted", "cancelled"] end)

        if Enum.empty?(incomplete_tasks) do
          finalize_completed_plan(plan_id, plan_store, tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.warning("Failed to list tasks for plan #{plan_id}: #{inspect(reason)}")
    end
  end

  defp finalize_completed_plan(plan_id, plan_store, tenant_id, user_id) do
    case plan_store.update(tenant_id, plan_id, %{"status" => "completed"}) do
      {:ok, updated_plan} ->
        Logger.info("Plan completed: plan_id=#{plan_id}")
        publish_plan_completion_event(plan_id, updated_plan, tenant_id, user_id)

      {:error, reason} ->
        Logger.error("Failed to update plan status: #{inspect(reason)}")
    end
  end

  defp publish_plan_completion_event(plan_id, updated_plan, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "events.gtd.plan.completed",
        %{
          "plan_id" => plan_id,
          "plan" => updated_plan,
          "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _} ->
        Logger.debug("Published plan completion event")

      {:error, reason} ->
        Logger.error("Failed to publish plan completion: #{inspect(reason)}")
    end
  end

  defp validate_fail_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_fail_payload(_), do: {:error, :invalid_payload}

  @doc false
  defp handle_plan_task_failure(failed_task, plan_id, failure_reason, tenant_id, user_id) do
    task_id = failed_task["id"]

    # Get the target bot from the task if available
    target_bot = Map.get(failed_task, "target_bot", "gtd")

    # Query dispatcher for confidence on retrying this bot
    confidence = ConfidenceAdapter.get_dispatcher_confidence(target_bot)
    retry_count = Map.get(failed_task, "retry_count", 0)

    Logger.info(
      "[TaskHandler] Evaluating plan failure: task_id=#{task_id}, confidence=#{confidence}, retry_count=#{retry_count}"
    )

    # Decide whether to retry or replan
    if ConfidenceAdapter.should_retry?(failed_task, confidence) do
      # Retry: increment counter and reschedule
      Logger.info("[TaskHandler] Retrying task: task_id=#{task_id}, confidence=#{confidence}")
      updated_task = ConfidenceAdapter.increment_retry_count(failed_task)

      # Reschedule task (delay for backoff)
      reschedule_task_for_retry(updated_task, confidence, tenant_id, user_id)
      emit_failure_decision_event(:retry, confidence, task_id, tenant_id, user_id)
    else
      # Replan: call plan adapter to regenerate remaining steps
      Logger.info(
        "[TaskHandler] Replanning after failure: task_id=#{task_id}, confidence=#{confidence}"
      )

      case PlanAdapter.replan_on_failure(
             plan_id,
             task_id,
             failure_reason,
             %{tenant_id: tenant_id, user_id: user_id}
           ) do
        {:ok, new_tasks} ->
          Logger.info(
            "[TaskHandler] Plan adapted: task_id=#{task_id}, new_task_count=#{length(new_tasks)}"
          )

          emit_failure_decision_event(:replan, confidence, task_id, tenant_id, user_id)

        {:error, reason} ->
          Logger.warning(
            "[TaskHandler] Plan adaptation failed: task_id=#{task_id}, reason=#{inspect(reason)}"
          )

          emit_failure_decision_event(:abort, confidence, task_id, tenant_id, user_id)
      end
    end
  end

  defp reschedule_task_for_retry(task, confidence, tenant_id, user_id) do
    task_id = task["id"]
    retry_count = Map.get(task, "retry_count", 0)

    # Exponential backoff: 5s, 25s, 125s, etc.
    backoff_multiplier = Integer.pow(5, retry_count)
    retry_delay_seconds = min(backoff_multiplier, 3600)

    # Reschedule to active after delay
    future_due_date =
      DateTime.utc_now()
      |> DateTime.add(retry_delay_seconds, :second)
      |> DateTime.to_iso8601()

    update_payload = %{
      "status" => "active",
      "due_date" => future_due_date,
      "retry_count" => retry_count
    }

    case scoped_update(tenant_id, task_id, update_payload) do
      {:ok, _updated_task} ->
        Logger.info(
          "[TaskHandler] Rescheduled task for retry: task_id=#{task_id}, retry_count=#{retry_count}, backoff_seconds=#{retry_delay_seconds}"
        )

      {:error, reason} ->
        Logger.warning(
          "[TaskHandler] Failed to reschedule task: task_id=#{task_id}, reason=#{inspect(reason)}"
        )
    end
  end

  defp emit_failure_decision_event(decision, confidence, task_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "events.gtd.plan.failure_decision",
        %{
          "task_id" => task_id,
          "decision" => decision,
          "dispatcher_confidence" => confidence,
          "decided_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("[TaskHandler] Published failure decision event: decision=#{decision}")

      {:error, reason} ->
        Logger.warning("[TaskHandler] Failed to publish failure decision: #{inspect(reason)}")
    end
  end
end

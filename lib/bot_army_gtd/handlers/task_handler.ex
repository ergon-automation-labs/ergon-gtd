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
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    BotArmyGtd.TaskIntakeGuard.log_caller_metadata("gtd.task.create", message)

    payload = maybe_stamp_active_until_for_create(payload)

    # Stamp tenant and user context into payload
    stamped_payload =
      Map.merge(payload, %{
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case validate_create_payload(stamped_payload) do
      :ok ->
        if BotArmyGtd.TaskIntakeGuard.suspicious_test_data?(message, stamped_payload) do
          Logger.warning(
            "Rejected suspicious test task create payload: event_id=#{event_id} payload=#{inspect(stamped_payload)}"
          )

          reason = :rejected_suspected_test_data
          publish_error(event_id, reason, "Rejected suspicious test data", tenant_id, user_id)
          {:error, reason}
        else
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

      {:error, reason} ->
        Logger.warning("Invalid task creation payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid task data", tenant_id, user_id)
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
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

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

            if old_status && new_status && old_status != new_status do
              BotArmyGtd.ParaExporter.notify_status_change(task, old_status, new_status)
            end

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
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

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

            BotArmyGtd.ParaExporter.notify_completed(task)
            BotArmyGtd.ParaExporter.rotate_next_action(task, tenant_id)

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
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

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
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

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

  # Private functions

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
    with :ok <- require_field(payload, "task_id"),
         :ok <- require_field(payload, "defer_until") do
      :ok
    end
  end

  defp validate_defer_payload(_), do: {:error, :invalid_payload}

  defp validate_delete_payload(payload) when is_map(payload) do
    require_field(payload, "task_id")
  end

  defp validate_delete_payload(_), do: {:error, :invalid_payload}

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
      BotArmyGtd.EventBuilder.build_event(
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

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published event: #{event_type}")
      {:error, reason} -> Logger.error("Failed to publish event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      BotArmyGtd.EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
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
        BotArmyGtd.EventBuilder.build_event("gtd.task.decompose", decom_payload,
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
            BotArmyGtd.ParaExporter.notify_task_created(task, project["name"])

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
        Enum.each(tasks, fn task ->
          case parse_active_until(task) do
            {:ok, active_until} ->
              if DateTime.compare(active_until, DateTime.utc_now()) == :lt do
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

            :none ->
              :ok

            {:error, _reason} ->
              :ok
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to list active tasks for expiry: #{inspect(reason)}")
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
              case parse_active_until(task) do
                {:ok, active_until} ->
                  if DateTime.compare(active_until, DateTime.utc_now()) == :lt do
                    demote_payload_to_inbox(payload, task)
                  else
                    refresh_payload_active_until(payload, task)
                  end

                _ ->
                  refresh_payload_active_until(payload, task)
              end

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
          # All tasks complete, update plan status
          case plan_store.update(tenant_id, plan_id, %{"status" => "completed"}) do
            {:ok, updated_plan} ->
              Logger.info("Plan completed: plan_id=#{plan_id}")

              # Publish plan completion event
              event_data =
                BotArmyGtd.EventBuilder.build_event(
                  "events.gtd.plan.completed",
                  %{
                    "plan_id" => plan_id,
                    "plan" => updated_plan,
                    "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                  },
                  tenant_id: tenant_id,
                  user_id: user_id
                )

              case BotArmyGtd.NATS.Publisher.publish(event_data) do
                {:ok, _} ->
                  Logger.debug("Published plan completion event")

                {:error, reason} ->
                  Logger.error("Failed to publish plan completion: #{inspect(reason)}")
              end

            {:error, reason} ->
              Logger.error("Failed to update plan status: #{inspect(reason)}")
          end
        end

      {:error, reason} ->
        Logger.warning("Failed to list tasks for plan #{plan_id}: #{inspect(reason)}")
    end
  end
end

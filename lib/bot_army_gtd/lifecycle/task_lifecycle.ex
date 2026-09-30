defmodule BotArmyGtd.TaskLifecycle do
  @moduledoc """
  Authoritative state machine for GTD task transitions.
  Encapsulates the business rules for task creation, updates, completion, 
  failure, and expiration.
  """

  require Logger
  alias BotArmyGtd.{
    ParaExporter,
    ScoreEngine,
    OutcomeTracker,
    TaskStore,
    ProjectStore,
    PlanStore,
    Adapters.ConfidenceAdapter,
    Adapters.PlanAdapter
  }
  alias BotArmyLibraryCore.{Tenant, OutcomesEmitter}
  alias BotArmyGtd.NATS.Publisher

  @active_until_key "active_until"
  @active_until_window_days 7

  @doc """
  Execute the logic for creating a task.
  """
  def create(tenant_id, user_id, payload, event_id, original_message) do
    payload = maybe_stamp_active_until_for_create(payload)
    
    stamped_payload = Map.merge(payload, %{"tenant_id" => tenant_id, "user_id" => user_id})

    # Validation is still handled by the handler for transport-level errors, 
    # but business-level guards can go here.
    case TaskStore.create(stamped_payload) do
      {:ok, task} ->
        Logger.info("Task created via Lifecycle: task_id=#{task["id"]}, event_id=#{event_id}")
        
        maybe_trigger_decomposition(task, payload, tenant_id, user_id)
        maybe_notify_para(task, tenant_id)
        recompute_score(tenant_id, task["id"])
        
        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute the logic for updating a task.
  """
  def update(tenant_id, user_id, task_id, payload) do
    {old_status, updated_payload} = apply_active_until_and_capture_status(tenant_id, task_id, payload)

    case TaskStore.update(tenant_id, task_id, updated_payload) do
      {:ok, task} ->
        Logger.info("Task updated via Lifecycle: task_id=#{task_id}")
        
        notify_status_change_if_needed(task, old_status, task["status"])
        recompute_score(tenant_id, task_id)
        
        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute the logic for completing a task.
  """
  def complete(tenant_id, user_id, task_id) do
    case TaskStore.complete(tenant_id, task_id) do
      {:ok, task} ->
        Logger.info("Task completed via Lifecycle: task_id=#{task_id}")

        ParaExporter.notify_completed(task)
        ParaExporter.rotate_next_action(task, tenant_id)
        maybe_handle_plan_completion(task, tenant_id, user_id)
        
        OutcomeTracker.record(task_id, "gtd.task_completion", "completed", "completed")
        OutcomesEmitter.emit_task_completed(task_id, %{
          "bot_name" => "gtd",
          "priority" => task["priority"],
          "project_id" => task["project_id"]
        })
        
        recompute_score(tenant_id, task_id)
        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute the logic for task failure.
  """
  def fail(tenant_id, user_id, task_id, failure_reason) do
    case TaskStore.update(tenant_id, task_id, %{"status" => "failed"}) do
      {:ok, task} ->
        handle_task_failure_by_plan(task, task_id, failure_reason, tenant_id, user_id)
        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Process task expirations.
  """
  def expire_active_tasks(tenant_id, user_id \\ nil) do
    filters = %{"status" => ["active"]}
    case TaskStore.list(tenant_id, filters) do
      {:ok, tasks} ->
        Enum.each(tasks, &process_expiry_for_task(&1, tenant_id, user_id))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private Logic ---

  defp recompute_score(tenant_id, task_id) do
    try do
      ScoreEngine.recompute_item(tenant_id, "task", task_id)
    rescue
      _ -> :ok
    end
  end

  defp maybe_trigger_decomposition(task, payload, tenant_id, user_id) do
    if Map.get(payload, "decompose", false) == true do
      decom_payload = %{
        "task_id" => task["id"],
        "model" => Map.get(payload, "decompose_model"),
        "chain_id" => Map.get(payload, "decompose_chain_id")
      } |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

      decompose_event = EventBuilder.build_event("gtd.task.decompose", decom_payload,
        tenant_id: tenant_id, user_id: user_id)

      Publisher.publish("gtd.task.decompose", decompose_event)
    end
  end

  defp maybe_notify_para(task, tenant_id) do
    project_id = task["project_id"]
    if is_binary(project_id) and project_id != "" and project_id != "_inbox" do
      case ProjectStore.get(tenant_id, project_id) do
        {:ok, project} -> ParaExporter.notify_task_created(task, project["name"])
        _ -> :ok
      end
    end
  end

  defp notify_status_change_if_needed(task, old_status, new_status) do
    if old_status && new_status && old_status != new_status do
      ParaExporter.notify_status_change(task, old_status, new_status)
    end
  end

  defp maybe_handle_plan_completion(task, tenant_id, user_id) do
    plan_id = task["plan_id"]
    if is_binary(plan_id) and plan_id != "" do
      case PlanStore.get(tenant_id, plan_id) do
        {:ok, plan} -> check_and_complete_plan_if_done(plan, tenant_id, user_id)
        _ -> :ok
      end
    end
  end

  defp check_and_complete_plan_if_done(plan, tenant_id, user_id) do
    plan_id = plan["id"]
    case TaskStore.list_by_plan(tenant_id, plan_id) do
      {:ok, tasks} ->
        incomplete_tasks = Enum.reject(tasks, fn t -> t["status"] in ["completed", "deleted", "cancelled"] end)
        if Enum.empty?(incomplete_tasks) do
          case PlanStore.update(tenant_id, plan_id, %{"status" => "completed"}) do
            {:ok, updated_plan} ->
              event_data = EventBuilder.build_event("events.gtd.plan.completed", %{
                "plan_id" => plan_id,
                "plan" => updated_plan,
                "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }, tenant_id: tenant_id, user_id: user_id)
              Publisher.publish(event_data)
            _ -> :ok
          end
        end
        :ok
      _ -> :ok
    end
  end

  defp handle_task_failure_by_plan(task, task_id, failure_reason, tenant_id, user_id) do
    plan_id = task["plan_id"]
    if is_binary(plan_id) and plan_id != "" do
      # Use ConfidenceAdapter and PlanAdapter for failure recovery logic
      target_bot = Map.get(task, "target_bot", "gtd")
      confidence = ConfidenceAdapter.get_dispatcher_confidence(target_bot)
      
      if ConfidenceAdapter.should_retry?(task, confidence) do
        updated_task = ConfidenceAdapter.increment_retry_count(task)
        reschedule_task_for_retry(updated_task, confidence, tenant_id, user_id)
      else
        PlanAdapter.replan_on_failure(plan_id, task_id, failure_reason, %{tenant_id: tenant_id, user_id: user_id})
      end
    end
  end

  defp reschedule_task_for_retry(task, _confidence, tenant_id, _user_id) do
    task_id = task["id"]
    retry_count = Map.get(task, "retry_count", 0)
    backoff = min(Integer.pow(5, retry_count), 3600)
    future_due = DateTime.utc_now() |> DateTime.add(backoff, :second) |> DateTime.to_iso8601()

    TaskStore.update(tenant_id, task_id, %{"status" => "active", "due_date" => future_due, "retry_count" => retry_count})
  end

  defp process_expiry_for_task(task, tenant_id, user_id) do
    case parse_active_until(task) do
      {:ok, active_until} ->
        if DateTime.compare(active_until, DateTime.utc_now()) == :lt do
          expire_task(task, tenant_id, user_id)
        end
      _ -> :ok
    end
  end

  defp expire_task(task, tenant_id, user_id) do
    task_id = task["id"]
    description = append_backlog_note(task["description"] || "")
    source_metadata = clear_active_until(task["source_metadata"])
    update_payload = %{"status" => "inbox", "description" => description, "source_metadata" => source_metadata}

    case TaskStore.update(tenant_id, task_id, update_payload) do
      {:ok, updated_task} ->
        event_data = EventBuilder.build_event("gtd.task.updated", update_payload, 
          updated_task, UUID.uuid4(), %{}, tenant_id, user_id)
        Publisher.publish(event_data)
      _ -> :ok
    end
  end

  defp maybe_stamp_active_until_for_create(payload) do
    if Map.get(payload, "status", "active") == "active" do
      source_metadata = stamp_active_until(Map.get(payload, "source_metadata"))
      Map.put(payload, "source_metadata", source_metadata)
    else
      payload
    end
  end

  defp apply_active_until_and_capture_status(tenant_id, task_id, payload) do
    case TaskStore.get(tenant_id, task_id) do
      {:ok, task} ->
        current_status = Map.get(task, "status")
        incoming_status = Map.get(payload, "status")
        updated_payload = 
          cond do
            incoming_status == "active" -> refresh_payload_active_until(payload, task)
            current_status == "active" -> handle_active_task_status(task, payload)
            true -> payload
          end
        {current_status, updated_payload}
      _ -> {nil, payload}
    end
  end

  defp refresh_payload_active_until(payload, task) do
    source_metadata = task |> Map.get("source_metadata") |> merge_source_metadata(Map.get(payload, "source_metadata")) |> stamp_active_until()
    Map.put(payload, "source_metadata", source_metadata)
  end

  defp handle_active_task_status(task, payload) do
    case parse_active_until(task) do
      {:ok, active_until} ->
        if DateTime.compare(active_until, DateTime.utc_now()) == :lt do
          demote_payload_to_inbox(payload, task)
        else
          refresh_payload_active_until(payload, task)
        end
      _ -> refresh_payload_active_until(payload, task)
    end
  end

  defp demote_payload_to_inbox(payload, task) do
    source_metadata = task |> Map.get("source_metadata") |> merge_source_metadata(Map.get(payload, "source_metadata")) |> clear_active_until()
    description = payload |> Map.get("description", task["description"] || "") |> append_backlog_note()
    payload |> Map.put("status", "inbox") |> Map.put("description", description) |> Map.put("source_metadata", source_metadata)
  end

  defp merge_source_metadata(existing, incoming) do
    Map.merge(if(is_map(existing), do: existing, else: %{}), if(is_map(incoming), do: incoming, else: %{}))
  end

  defp stamp_active_until(source_metadata) do
    metadata = if is_map(source_metadata), do: source_metadata, else: %{}
    active_until = DateTime.utc_now() |> DateTime.add(@active_until_window_days * 24 * 60 * 60, :second) |> DateTime.to_iso8601()
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
      _ -> :none
    end
  end

  defp append_backlog_note(description) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    note = "[PUSHED_TO_BACKLOG #{timestamp}] active_until expired; moved to inbox for re-prioritization."
    if String.contains?(description, "active_until expired; moved to inbox") do
      description
    else
      (description <> "\n\n" <> note) |> String.trim()
    end
  end
end

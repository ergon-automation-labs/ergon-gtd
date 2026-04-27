defmodule BotArmyGtd.Handlers.InboxParsingHandler do
  @moduledoc """
  Handles parsed inbox text from LLM bot.

  This handler processes responses from llm.response.parse events, extracting
  structured task data (title, description, project, priority, due_date, tags)
  and creating a task in the TaskStore.

  Processes incoming messages:
  - `llm.response.parsed` - Parsed inbox text with extracted task fields

  Dependencies:
  - BotArmyGtd.TaskStore
  - BotArmyGtd.NATS.Publisher
  - BotArmyLlm.LlmClient (for testing/validation, injected)
  """

  require Logger

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle parsed inbox text response from LLM.

  Validates the parsed data, extracts task fields, and creates a task.
  Publishes gtd.task.created on success or gtd.error on failure.

  Returns `:ok` if successful.
  """
  def handle_parse(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    BotArmyGtd.TaskIntakeGuard.log_caller_metadata("llm.response.parsed", message)

    case validate_parse_payload(payload) do
      :ok ->
        if BotArmyGtd.TaskIntakeGuard.suspicious_test_data?(message, payload) do
          Logger.warning(
            "Rejected suspicious parsed payload: event_id=#{event_id} payload=#{inspect(payload)}"
          )

          publish_error(
            event_id,
            :rejected_suspected_test_data,
            "Rejected suspicious test data",
            tenant_id,
            user_id
          )
        else
          process_parse(payload, event_id, message, tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.warning("Invalid parse payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid parsed data", tenant_id, user_id)
    end
  end

  # Private validation

  defp validate_parse_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "structured_data") do
      # Validate that structured_data is a map
      case payload do
        %{"structured_data" => data} when is_map(data) -> :ok
        _ -> {:error, :structured_data_not_map}
      end
    end
  end

  defp validate_parse_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  # Private processing

  defp process_parse(payload, event_id, _message, tenant_id, user_id) do
    structured_data = payload["structured_data"]
    inbox_item_id = payload["inbox_item_id"]
    source = payload["source"] || "user"
    source_metadata = payload["source_metadata"] || %{}

    # Extract task fields from structured data, with defaults
    title = structured_data["title"] || "Untitled Task"
    description = structured_data["description"] || nil
    project = structured_data["project"] || "_inbox"
    priority = structured_data["priority"] || "normal"
    due_date = structured_data["due_date"] || nil
    labels = structured_data["labels"] || structured_data["tags"] || []

    # Create task with parsed data
    case task_store().create(%{
           "tenant_id" => tenant_id,
           "user_id" => user_id,
           "title" => title,
           "description" => description,
           "project_id" => project,
           "status" => "inbox",
           "priority" => priority,
           "due_date" => due_date,
           "labels" => labels,
           "source" => source,
           "source_metadata" => source_metadata,
           "inbox_item_id" => inbox_item_id
         }) do
      {:ok, task} ->
        Logger.info("Parsed task created: task_id=#{task["id"]}, event_id=#{event_id}")
        publish_task_created(task, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.error("Failed to create task from parsed data: #{inspect(reason)}")

        publish_error(
          event_id,
          reason,
          "Failed to create task from parsed data",
          tenant_id,
          user_id
        )
    end
  end

  # Private publishing

  defp publish_task_created(task, event_id, tenant_id, user_id) do
    event_data =
      BotArmyGtd.EventBuilder.build_event(
        "gtd.task.created",
        %{
          "task" => task,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published task.created event from parsed inbox")
      {:error, reason} -> Logger.error("Failed to publish task event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      BotArmyGtd.EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} -> Logger.debug("Published error event from parsing handler")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end

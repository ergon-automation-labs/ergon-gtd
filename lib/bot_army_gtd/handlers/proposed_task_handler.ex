defmodule BotArmyGtd.Handlers.ProposedTaskHandler do
  @moduledoc """
  Handles the approval and rejection of proposed tasks (automated brain tasks).

  Proposed tasks are created by LLM parsing or decomposition and are held in a
  "proposed" state to prevent them from cluttering the active list.
  """

  require Logger
  alias BotArmyLibraryCore.Tenant
  alias BotArmyGtd.{NATS.Publisher, EventBuilder}

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Approve a proposed task, moving it to the inbox.
  """
  def handle_approve(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case payload do
      %{"task_id" => task_id} ->
        # Move status from "proposed" to "inbox"
        update_payload = %{
          "status" => "inbox",
          "user_id" => user_id
        }

        case task_store().update(tenant_id, task_id, update_payload) do
          {:ok, task} ->
            Logger.info("Proposed task approved: task_id=#{task_id}")
            publish_approved(task, event_id, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to approve proposed task: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to approve proposed task", tenant_id, user_id)
        end

      _ ->
        Logger.warning("Invalid approval payload: #{inspect(payload)}")
        publish_error(event_id, :invalid_payload, "Missing task_id in payload", tenant_id, user_id)
    end
  end

  @doc """
  Reject a proposed task, marking it as deleted/archived.
  """
  def handle_reject(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    case payload do
      %{"task_id" => task_id} ->
        update_payload = %{
          "status" => "deleted",
          "user_id" => user_id
        }

        case task_store().update(tenant_id, task_id, update_payload) do
          {:ok, task} ->
            Logger.info("Proposed task rejected: task_id=#{task_id}")
            publish_rejected(task, event_id, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to reject proposed task: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to reject proposed task", tenant_id, user_id)
        end

      _ ->
        Logger.warning("Invalid rejection payload: #{inspect(payload)}")
        publish_error(event_id, :invalid_payload, "Missing task_id in payload", tenant_id, user_id)
    end
  end

  defp publish_approved(task, event_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "gtd.task.proposed_approved",
        %{
          "task" => task,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    Publisher.publish(event_data)
  end

  defp publish_rejected(task, event_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build_event(
        "gtd.task.proposed_rejected",
        %{
          "task" => task,
          "triggered_by_event_id" => event_id
        },
        tenant_id: tenant_id,
        user_id: user_id
      )

    Publisher.publish(event_data)
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    event_data =
      EventBuilder.build_error(event_id, reason, message,
        tenant_id: tenant_id,
        user_id: user_id
      )

    Publisher.publish(event_data)
  end
end

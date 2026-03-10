defmodule BotArmyGtd.Handlers.ProjectHandler do
  @moduledoc """
  Handles project-related events for the GTD bot.

  This module processes incoming project messages:
  - `gtd.project.create` - Create a new project
  - `gtd.project.update` - Update existing project

  Each operation validates the input, performs the action, and publishes
  corresponding response events.

  ## Dependencies

  - `BotArmyGtd.ProjectStore` - Persistent project storage
  - `BotArmyGtd.NATS.Publisher` - Event publishing
  """

  require Logger

  defp project_store do
    Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)
  end

  @doc """
  Handle project creation event.

  Validates the project data, stores it, and publishes a project.created event.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_create(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_create_payload(payload) do
      :ok ->
        case project_store().create(payload) do
          {:ok, project} ->
            Logger.info("Project created: project_id=#{project.id}, event_id=#{event_id}")
            publish_event("gtd.project.created", payload, project, event_id, message)

          {:error, reason} ->
            Logger.error("Failed to create project: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to create project")
        end

      {:error, reason} ->
        Logger.warning("Invalid project creation payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid project data")
    end
  end

  @doc """
  Handle project update event.

  Validates the update data, applies it, and publishes a project.updated event.
  """
  def handle_update(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_update_payload(payload) do
      :ok ->
        project_id = payload["project_id"]

        case project_store().update(project_id, payload) do
          {:ok, project} ->
            Logger.info("Project updated: project_id=#{project_id}, event_id=#{event_id}")
            publish_event("gtd.project.updated", payload, project, event_id, message)

          {:error, reason} ->
            Logger.error("Failed to update project #{project_id}: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to update project")
        end

      {:error, reason} ->
        Logger.warning("Invalid project update payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid project data")
    end
  end

  # Private functions

  defp validate_create_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "name") do
      :ok
    end
  end

  defp validate_create_payload(_), do: {:error, :invalid_payload}

  defp validate_update_payload(payload) when is_map(payload) do
    require_field(payload, "project_id")
  end

  defp validate_update_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp publish_event(event_type, _payload, project, event_id, _original_message) do
    event_data = %{
      "event" => event_type,
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => get_node_name(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "project" => project,
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published event: #{event_type}")
      {:error, reason} -> Logger.error("Failed to publish event: #{inspect(reason)}")
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
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end

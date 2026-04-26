defmodule BotArmyGtd.Handlers.SearchHandler do
  @moduledoc """
  Handles task search requests for the GTD bot.

  Searches tasks by query string with optional filters.
  """

  require Logger

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  @doc """
  Handle task search request.

  Validates the search payload, searches tasks, and returns results.
  """
  def handle_search(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    case validate_search_payload(payload) do
      :ok ->
        query = payload["query"]
        filters = Map.get(payload, "filters", %{})
        pagination = Map.get(payload, "pagination", %{})

        case task_store().search(tenant_id, query, filters, pagination) do
          {:ok, {tasks, total_count}} ->
            Logger.info(
              "Searched tasks: query=#{query}, results=#{length(tasks)}, event_id=#{event_id}"
            )

            results = %{
              "tasks" => tasks,
              "total_count" => total_count,
              "limit" => Map.get(pagination, "limit", 50),
              "offset" => Map.get(pagination, "offset", 0),
              "query" => query
            }

            {:ok, results}

          {:error, reason} ->
            Logger.error("Failed to search tasks: #{inspect(reason)}")
            {:error, :search_failed}
        end

      {:error, reason} ->
        Logger.warning("Invalid search payload: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp validate_search_payload(payload) when is_map(payload) do
    require_field(payload, "query")
  end

  defp validate_search_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end
end

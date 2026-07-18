defmodule BotArmyGtd.Handlers.SearchHandler do
  @moduledoc """
  Handles task search requests for the GTD bot.

  Searches tasks by query string with optional filters.

  When `filters["no_project"]` is true, results are limited to tasks with no
  `project_id` (empty desk hygiene for chronicle / daily brief). Omitted or blank
  `query` is normalized to `"*"` (match all) for that case. A plain `"*"` query
  without `no_project` still matches every task textually.
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
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)

    case validate_search_payload(payload) do
      :ok ->
        filters = Map.get(payload, "filters", %{})
        query = normalize_search_query(payload["query"], filters)
        pagination = Map.get(payload, "pagination", %{})

        case task_store().search(tenant_id, query, filters, pagination) do
          {:ok, {tasks, total_count}} ->
            Logger.info(
              "Searched tasks: query=#{query}, results=#{length(tasks)}, user_id=#{user_id}, event_id=#{event_id}"
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
    filters = Map.get(payload, "filters", %{})
    allow_blank_query? = Map.get(filters, "no_project") == true
    query = Map.get(payload, "query")

    cond do
      allow_blank_query? and blank_query?(query) ->
        :ok

      is_binary(query) and String.trim(query) != "" ->
        :ok

      true ->
        {:error, {:missing_field, "query"}}
    end
  end

  defp validate_search_payload(_), do: {:error, :invalid_payload}

  defp blank_query?(q) when q in [nil, ""], do: true
  defp blank_query?(q) when is_binary(q), do: String.trim(q) == ""
  defp blank_query?(_), do: false

  defp normalize_search_query(query, filters) do
    if Map.get(filters, "no_project") == true and blank_query?(query) do
      "*"
    else
      query
    end
  end
end

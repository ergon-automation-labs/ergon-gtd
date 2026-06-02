defmodule BotArmyGtd.Handlers.WhatsNextHandler do
  @moduledoc """
  Handler for the "what's next" query to suggest the next best action for users.
  """
  require Logger
  alias Ecto.UUID

  def handle_request(message) do
    params = message["payload"] || message

    tenant_id =
      params["tenant_id"] || message["tenant_id"] ||
        Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    limit_human = Map.get(params, "limit_human", 5)
    limit_bot = Map.get(params, "limit_bot", 10)
    # Normalize plural form to singular (tasks -> task, etc.)
    raw_include = Map.get(params, "include", ["task", "project", "goal"])
    include = Enum.map(raw_include, &String.replace_suffix(&1, "s", ""))

    Logger.debug("[WhatsNextHandler] tenant=#{tenant_id}, include=#{inspect(include)}")
    scores = query_scores(tenant_id)
    Logger.debug("[WhatsNextHandler] scores count=#{length(scores)}")

    # Enrich scores with full task details for categorization
    task_scores = Enum.filter(scores, &(&1["item_type"] == "task"))
    enriched_tasks = enrich_with_task_details(tenant_id, task_scores)

    result = %{
      "human" => categorize_tasks(enriched_tasks, limit_human),
      "bots" => %{"task" => Enum.take(enriched_tasks, limit_bot)},
      "due_today" => filter_due_today(enriched_tasks) |> Enum.take(limit_human),
      "in_progress" => filter_status(enriched_tasks, "active") |> Enum.take(limit_human),
      "snapshot_generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "score_version" => "v1"
    }

    {:ok, result}
  end

  defp query_scores(tenant_id) do
    import Ecto.Query

    BotArmyGtd.Schemas.ItemScore
    |> where([s], s.tenant_id == ^tenant_id)
    |> order_by([s], desc: s.why_next_score)
    |> BotArmyGtd.Repo.all()
    |> Enum.map(&score_to_map/1)
  rescue
    e ->
      Logger.error("[WhatsNextHandler] Error querying scores: #{inspect(e)}")
      []
  end

  defp build_ranked_snapshot(scores, _source, include, limit) do
    grouped =
      scores
      |> Enum.filter(fn s -> s["item_type"] in include end)
      |> Enum.group_by(fn s -> s["item_type"] end)

    Map.new(grouped, fn {item_type, items} ->
      {item_type, Enum.take(items, limit)}
    end)
  end

  defp score_to_map(%BotArmyGtd.Schemas.ItemScore{} = score) do
    %{
      "item_type" => score.item_type,
      "item_id" => to_string(score.item_id),
      "why_next_score" => score.why_next_score,
      "why_next_reason" => score.why_next_reason,
      "top_evidence" => score.top_evidence || []
    }
  end

  defp enrich_with_task_details(tenant_id, scores) do
    import Ecto.Query

    # Convert string UUIDs to binary safely
    task_ids =
      scores
      |> Enum.map(fn score ->
        case UUID.cast(score["item_id"]) do
          {:ok, binary} -> binary
          :error -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(task_ids) do
      # No valid task IDs, return scores as-is
      Enum.sort_by(scores, & &1["why_next_score"], :desc)
    else
      tasks =
        BotArmyGtd.Schemas.Task
        |> where([t], t.tenant_id == ^tenant_id and t.id in ^task_ids)
        |> BotArmyGtd.Repo.all()
        |> Enum.map(&task_to_map/1)
        |> Map.new(fn t -> {t["id"], t} end)

      # Merge scores with task details
      Enum.map(scores, fn score ->
        Map.merge(score, Map.get(tasks, score["item_id"], %{}))
      end)
      |> Enum.sort_by(& &1["why_next_score"], :desc)
    end
  rescue
    e ->
      Logger.error("[WhatsNextHandler] Error enriching tasks: #{inspect(e)}")
      Enum.sort_by(scores, & &1["why_next_score"], :desc)
  end

  defp task_to_map(task) do
    %{
      "id" => UUID.binary_to_string!(task.id),
      "title" => task.title,
      "status" => task.status,
      "due_date" => task.due_date,
      "priority" => task.priority
    }
  end

  defp categorize_tasks(tasks, limit) do
    %{
      "task" => Enum.take(tasks, limit)
    }
  end

  defp filter_due_today(tasks) do
    today = DateTime.utc_now() |> DateTime.to_date()

    Enum.filter(tasks, fn t ->
      case t["due_date"] do
        %DateTime{} = dt -> DateTime.to_date(dt) == today
        nil -> false
        _ -> false
      end
    end)
    |> Enum.sort_by(& &1["why_next_score"], :desc)
  end

  defp filter_status(tasks, status) do
    Enum.filter(tasks, &(&1["status"] == status))
    |> Enum.sort_by(& &1["why_next_score"], :desc)
  end
end

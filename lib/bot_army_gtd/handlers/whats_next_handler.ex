defmodule BotArmyGtd.Handlers.WhatsNextHandler do
  @moduledoc """
  Handler for the "what's next" query to suggest the next best action for users.
  """
  require Logger

  def handle_request(message) do
    params = message["payload"] || message

    tenant_id =
      params["tenant_id"] || message["tenant_id"] ||
        Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    limit_human = Map.get(params, "limit_human", 5)
    limit_bot = Map.get(params, "limit_bot", 10)
    include = Map.get(params, "include", ["tasks", "projects", "goals"])

    scores = query_scores(tenant_id)

    result = %{
      "human" => build_ranked_snapshot(scores, "human", include, limit_human),
      "bots" => build_ranked_snapshot(scores, "bot", include, limit_bot),
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
    _ ->
      Logger.warning("Could not query item scores for whats_next")
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
end

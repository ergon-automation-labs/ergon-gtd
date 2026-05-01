defmodule BotArmyGtd.ScoreEngine do
  require Logger
  import Ecto.Query

  def recompute_from_vote_totals(tenant_id, vote_totals) do
    Enum.each(vote_totals, fn total ->
      recompute_item(tenant_id, total["item_type"], total["item_id"])
    end)
  end

  def recompute_item(tenant_id, item_type, item_id) do
    signals = query_signals(tenant_id, item_type, item_id)
    score = aggregate_score(signals)
    evidence = build_evidence(signals)

    upsert_score(tenant_id, item_type, item_id, score, evidence)
  end

  defp query_signals(tenant_id, item_type, item_id) do
    try do
      BotArmyGtd.Schemas.ItemSignal
      |> where(
        [s],
        s.tenant_id == ^tenant_id and s.item_type == ^item_type and s.item_id == ^item_id
      )
      |> BotArmyGtd.Repo.all()
    rescue
      _ -> []
    end
  end

  defp aggregate_score(signals) do
    Enum.reduce(signals, 0.0, fn signal, acc -> acc + (signal.signal_value || 0.0) end)
  end

  defp build_evidence(signals) do
    signals
    |> Enum.sort_by(& &1.signal_value, :desc)
    |> Enum.take(5)
    |> Enum.map(fn s ->
      "#{s.signal_type}: #{s.signal_value} (#{s.source})"
    end)
  end

  defp upsert_score(tenant_id, item_type, item_id, score, evidence) do
    try do
      existing =
        BotArmyGtd.Schemas.ItemScore
        |> where(
          [s],
          s.tenant_id == ^tenant_id and s.item_type == ^item_type and s.item_id == ^item_id
        )
        |> BotArmyGtd.Repo.one()

      case existing do
        nil ->
          %BotArmyGtd.Schemas.ItemScore{id: Ecto.UUID.generate()}
          |> BotArmyGtd.Schemas.ItemScore.changeset(%{
            "tenant_id" => tenant_id,
            "item_type" => item_type,
            "item_id" => item_id,
            "why_next_score" => score,
            "why_next_reason" => "aggregated from #{length(evidence)} signals",
            "top_evidence" => evidence,
            "score_version" => "v1"
          })
          |> BotArmyGtd.Repo.insert()

        existing_score ->
          existing_score
          |> BotArmyGtd.Schemas.ItemScore.changeset(%{
            "why_next_score" => score,
            "why_next_reason" => "aggregated from #{length(evidence)} signals",
            "top_evidence" => evidence
          })
          |> BotArmyGtd.Repo.update()
      end
    rescue
      e -> Logger.warning("Failed to upsert score: #{inspect(e)}")
    end
  end
end

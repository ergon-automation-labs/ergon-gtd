defmodule BotArmyGtd.ScoreEngine do
  require Logger
  import Ecto.Query

  alias BotArmyGtd.Repo
  alias BotArmyGtd.Schemas.{ItemScore, ItemSignal}

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
    ItemSignal
    |> where(
      [s],
      s.tenant_id == ^tenant_id and s.item_type == ^item_type and s.item_id == ^item_id
    )
    |> Repo.all()
  rescue
    e ->
      Logger.warning("[ScoreEngine] Failed to query signals",
        item_type: item_type,
        item_id: item_id,
        error: inspect(e)
      )

      []
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
    existing =
      ItemScore
      |> where(
        [s],
        s.tenant_id == ^tenant_id and s.item_type == ^item_type and s.item_id == ^item_id
      )
      |> Repo.one()

    case existing do
      nil ->
        %ItemScore{id: Ecto.UUID.generate()}
        |> ItemScore.changeset(%{
          "tenant_id" => tenant_id,
          "item_type" => item_type,
          "item_id" => item_id,
          "why_next_score" => score,
          "why_next_reason" => "aggregated from #{length(evidence)} signals",
          "top_evidence" => evidence,
          "score_version" => "v1"
        })
        |> Repo.insert()

      existing_score ->
        existing_score
        |> ItemScore.changeset(%{
          "why_next_score" => score,
          "why_next_reason" => "aggregated from #{length(evidence)} signals",
          "top_evidence" => evidence
        })
        |> Repo.update()
    end
  rescue
    e ->
      Logger.warning("[ScoreEngine] Failed to upsert score",
        item_type: item_type,
        item_id: item_id,
        score: score,
        error: inspect(e)
      )
  end
end

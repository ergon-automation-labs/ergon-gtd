defmodule BotArmyGtd.Repo.Migrations.CreateGtdItemScores do
  use Ecto.Migration

  def change do
    create table(:gtd_item_scores, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:item_type, :string, null: false)
      add(:item_id, :uuid, null: false)
      add(:why_next_score, :float, default: 0.0, null: false)
      add(:why_next_reason, :string)
      add(:top_evidence, :map, default: [])
      add(:score_version, :string, default: "v1", null: false)
      add(:tenant_id, :uuid, null: false)

      timestamps()
    end

    create(unique_index(:gtd_item_scores, [:item_type, :item_id, :tenant_id]))
  end
end

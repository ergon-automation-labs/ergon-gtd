defmodule BotArmyGtd.Repo.Migrations.CreateGtdItemSignals do
  use Ecto.Migration

  def change do
    create table(:gtd_item_signals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:item_type, :string, null: false)
      add(:item_id, :uuid, null: false)
      add(:signal_type, :string, null: false)
      add(:signal_value, :float, null: false)
      add(:source, :string, null: false)
      add(:tenant_id, :uuid, null: false)

      timestamps()
    end

    create(index(:gtd_item_signals, [:item_type, :item_id]))
    create(index(:gtd_item_signals, [:tenant_id]))
  end
end

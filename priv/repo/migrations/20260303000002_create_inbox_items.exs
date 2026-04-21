defmodule BotArmyGtd.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  def change do
    create table(:inbox_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:raw_text, :text, null: false, comment: "Raw inbox item text")
      add(:source, :string, null: false, default: "user", comment: "Source of inbox item")
      add(:source_metadata, :map, comment: "JSONB metadata from source")
      add(:received_at, :naive_datetime, null: false, comment: "When inbox item was received")
      add(:processed_at, :naive_datetime, comment: "When inbox item was processed/clarified")

      add(:status, :string,
        null: false,
        default: "pending",
        comment: "pending|clarified|discarded"
      )

      # Multitenancy
      add(:tenant_id, :uuid, null: false)
      add(:user_id, :uuid, null: false)

      timestamps()
    end

    create(index(:inbox_items, [:status]))
    create(index(:inbox_items, [:source]))
    create(index(:inbox_items, [:tenant_id]))
    create(index(:inbox_items, [:user_id]))
  end
end

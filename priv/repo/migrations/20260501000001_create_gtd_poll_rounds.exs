defmodule BotArmyGtd.Repo.Migrations.CreateGtdPollRounds do
  use Ecto.Migration

  def change do
    create table(:gtd_poll_rounds, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:vote_budget_per_bot, :integer, default: 3, null: false)
      add(:snapshot_json, :map)
      add(:status, :string, default: "open", null: false)
      add(:closes_at, :utc_datetime)
      add(:tenant_id, :uuid, null: false)
      add(:user_id, :uuid, null: false)

      timestamps()
    end

    create(index(:gtd_poll_rounds, [:tenant_id]))
    create(index(:gtd_poll_rounds, [:status]))
    create(index(:gtd_poll_rounds, [:tenant_id, :status]))
  end
end

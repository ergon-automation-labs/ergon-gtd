defmodule BotArmyGtd.Repo.Migrations.AddTenantIdToPollVotes do
  use Ecto.Migration

  def change do
    alter table(:gtd_poll_votes) do
      add(:tenant_id, :uuid, null: false, default: "00000000-0000-0000-0000-000000000001")
    end

    create(index(:gtd_poll_votes, [:tenant_id, :poll_id]))
  end
end

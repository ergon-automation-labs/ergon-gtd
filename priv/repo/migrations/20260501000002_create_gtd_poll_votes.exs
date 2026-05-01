defmodule BotArmyGtd.Repo.Migrations.CreateGtdPollVotes do
  use Ecto.Migration

  def change do
    create table(:gtd_poll_votes, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:poll_id, references(:gtd_poll_rounds, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:voter_type, :string, null: false)
      add(:voter_id, :string, null: false)
      add(:item_type, :string, null: false)
      add(:item_id, :uuid, null: false)
      add(:votes, :integer, null: false, default: 1)

      timestamps()
    end

    create(
      unique_index(:gtd_poll_votes, [:poll_id, :voter_type, :voter_id, :item_type, :item_id],
        name: :poll_votes_unique_allocation
      )
    )

    create(index(:gtd_poll_votes, [:poll_id]))
  end
end

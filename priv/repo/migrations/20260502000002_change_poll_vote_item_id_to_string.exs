defmodule BotArmyGtd.Repo.Migrations.ChangePollVoteItemIdToString do
  use Ecto.Migration

  def up do
    alter table(:gtd_poll_votes) do
      modify(:item_id, :text)
    end

    drop_if_exists(index(:gtd_poll_votes, [:tenant_id, :poll_id]))

    drop_if_exists(
      unique_index(:gtd_poll_votes, [:poll_id, :voter_type, :voter_id, :item_type, :item_id],
        name: :poll_votes_unique_allocation
      )
    )

    create(index(:gtd_poll_votes, [:tenant_id, :poll_id]))

    create(
      unique_index(:gtd_poll_votes, [:poll_id, :voter_type, :voter_id, :item_type, :item_id],
        name: :poll_votes_unique_allocation
      )
    )
  end

  def down do
    alter table(:gtd_poll_votes) do
      modify(:item_id, :uuid)
    end
  end
end

defmodule BotArmyGtd.Schemas.PollVote do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "gtd_poll_votes" do
    field(:voter_type, :string)
    field(:voter_id, :string)
    field(:item_type, :string)
    field(:item_id, :string)
    field(:votes, :integer, default: 1)
    field(:tenant_id, Ecto.UUID)

    belongs_to(:poll_round, BotArmyGtd.Schemas.PollRound, foreign_key: :poll_id)

    timestamps()
  end

  def changeset(poll_vote, attrs) do
    poll_vote
    |> cast(attrs, [:poll_id, :voter_type, :voter_id, :item_type, :item_id, :votes, :tenant_id])
    |> validate_required([:poll_id, :voter_type, :voter_id, :item_type, :item_id, :votes])
    |> validate_inclusion(:voter_type, ["bot", "human"])
    |> validate_inclusion(:item_type, ["task", "project", "goal"])
    |> validate_number(:votes, greater_than: 0)
    |> unique_constraint([:poll_id, :voter_type, :voter_id, :item_type, :item_id],
      name: :poll_votes_unique_allocation
    )
  end
end

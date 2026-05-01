defmodule BotArmyGtd.Schemas.PollRound do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "gtd_poll_rounds" do
    field(:name, :string)
    field(:vote_budget_per_bot, :integer, default: 3)
    field(:snapshot_json, :map)
    field(:status, :string, default: "open")
    field(:closes_at, :utc_datetime)
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)

    has_many(:votes, BotArmyGtd.Schemas.PollVote, foreign_key: :poll_id)

    timestamps()
  end

  def changeset(poll_round, attrs) do
    poll_round
    |> cast(attrs, [
      :name,
      :vote_budget_per_bot,
      :snapshot_json,
      :status,
      :closes_at,
      :tenant_id,
      :user_id
    ])
    |> validate_required([:name, :tenant_id])
    |> validate_inclusion(:status, ["open", "closed"])
    |> validate_number(:vote_budget_per_bot, greater_than: 0)
  end
end

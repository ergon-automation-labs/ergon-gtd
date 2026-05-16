defmodule BotArmyGtd.Schemas.ItemScore do
  @moduledoc """
  Schema for storing calculated scores for GTD items (tasks, projects, decompositions).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "gtd_item_scores" do
    field(:item_type, :string)
    field(:item_id, Ecto.UUID)
    field(:why_next_score, :float, default: 0.0)
    field(:why_next_reason, :string)
    field(:top_evidence, {:array, :map}, default: [])
    field(:score_version, :string, default: "v1")
    field(:tenant_id, Ecto.UUID)

    timestamps()
  end

  def changeset(item_score, attrs) do
    item_score
    |> cast(attrs, [
      :item_type,
      :item_id,
      :why_next_score,
      :why_next_reason,
      :top_evidence,
      :score_version,
      :tenant_id
    ])
    |> validate_required([:item_type, :item_id, :tenant_id])
    |> validate_inclusion(:item_type, ["task", "project", "goal"])
    |> unique_constraint([:item_type, :item_id, :tenant_id])
  end
end

defmodule BotArmyGtd.Schemas.InboxItem do
  @moduledoc """
  Ecto schema for GTD inbox items.

  Represents items in the inbox that need to be clarified and converted
  to actionable tasks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "inbox_items" do
    field :raw_text, :string
    field :source, :string, default: "user"
    field :source_metadata, :map
    field :received_at, :naive_datetime
    field :processed_at, :naive_datetime
    field :status, :string, default: "pending"
    field :tenant_id, :binary_id
    field :user_id, :binary_id

    timestamps()
  end

  @doc false
  def changeset(inbox_item, attrs) do
    inbox_item
    |> cast(attrs, [:raw_text, :source, :source_metadata, :received_at, :processed_at, :status, :tenant_id, :user_id])
    |> validate_required([:raw_text, :received_at])
    |> validate_inclusion(:status, ["pending", "clarified", "discarded"])
  end
end

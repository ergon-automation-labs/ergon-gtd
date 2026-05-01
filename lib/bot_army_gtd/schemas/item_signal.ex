defmodule BotArmyGtd.Schemas.ItemSignal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "gtd_item_signals" do
    field(:item_type, :string)
    field(:item_id, Ecto.UUID)
    field(:signal_type, :string)
    field(:signal_value, :float)
    field(:source, :string)
    field(:tenant_id, Ecto.UUID)

    timestamps()
  end

  def changeset(item_signal, attrs) do
    item_signal
    |> cast(attrs, [:item_type, :item_id, :signal_type, :signal_value, :source, :tenant_id])
    |> validate_required([:item_type, :item_id, :signal_type, :signal_value, :source, :tenant_id])
    |> validate_inclusion(:item_type, ["task", "project", "goal"])
  end
end

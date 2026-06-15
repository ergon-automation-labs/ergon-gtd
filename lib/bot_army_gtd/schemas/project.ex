defmodule BotArmyGtd.Schemas.Project do
  @moduledoc """
  Ecto schema for GTD projects.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "projects" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:area, :string)
    field(:labels, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})
    field(:parent_project_id, Ecto.UUID)
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)

    has_many(:tasks, BotArmyGtd.Schemas.Task)
    has_many(:subprojects, __MODULE__, foreign_key: :parent_project_id)

    belongs_to(:parent_project, __MODULE__,
      foreign_key: :parent_project_id,
      type: Ecto.UUID,
      define_field: false
    )

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :area,
      :labels,
      :metadata,
      :parent_project_id,
      :tenant_id,
      :user_id
    ])
    |> validate_required([:name])
    |> validate_inclusion(:status, ["active", "archived", "completed"])
  end
end

defmodule BotArmyGtd.Schemas.Task do
  @moduledoc """
  Ecto schema for GTD tasks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"
    field :priority, :string, default: "normal"
    field :due_date, :date
    field :completed_at, :naive_datetime
    field :project_id, :string

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :status, :priority, :due_date, :completed_at, :project_id])
    |> validate_required([:title])
    |> validate_inclusion(:status, ["active", "completed", "archived"])
    |> validate_inclusion(:priority, ["low", "normal", "high"])
  end
end

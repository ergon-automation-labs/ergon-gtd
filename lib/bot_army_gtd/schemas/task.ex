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
    field :context, :string
    field :source, :string, default: "user"
    field :source_metadata, :map
    field :due_date, :date
    field :completed_at, :naive_datetime
    field :project_id, :string
    field :tenant_id, Ecto.UUID
    field :user_id, Ecto.UUID

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :context,
      :source,
      :source_metadata,
      :due_date,
      :completed_at,
      :project_id,
      :tenant_id,
      :user_id
    ])
    |> validate_required([:title, :tenant_id])
    |> validate_inclusion(:status, [
      "inbox",
      "next_action",
      "waiting_for",
      "someday_maybe",
      "reference",
      "done",
      "deleted",
      "active",
      "completed",
      "archived"
    ])
    |> validate_inclusion(:priority, ["low", "normal", "high"])
  end
end

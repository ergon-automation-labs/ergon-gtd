defmodule BotArmyGtd.Schemas.Task do
  @moduledoc """
  Ecto schema for GTD tasks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:priority, :string, default: "normal")
    field(:context, :string)
    field(:source, :string, default: "user")
    field(:source_metadata, :map)
    field(:due_date, :date)
    field(:completed_at, :naive_datetime)
    field(:project_id, :string)
    field(:goal_id, :string)
    field(:parent_task_id, Ecto.UUID)
    field(:labels, {:array, :string}, default: [])
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:result, :map)
    field(:generated_by_ai, :boolean, default: false)
    field(:plan_id, Ecto.UUID)
    field(:plan_order, :integer)
    field(:verified_by, :string)

    # Relationships - parent_task_id stored as string for simplicity
    belongs_to(:parent_task, __MODULE__,
      foreign_key: :parent_task_id,
      type: Ecto.UUID,
      define_field: false
    )

    has_many(:subtasks, __MODULE__, foreign_key: :parent_task_id)

    # Plan relationship
    belongs_to(:plan, BotArmyGtd.Schemas.Plan,
      foreign_key: :plan_id,
      type: Ecto.UUID,
      define_field: false
    )

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
      :goal_id,
      :parent_task_id,
      :labels,
      :tenant_id,
      :user_id,
      :result,
      :generated_by_ai,
      :plan_id,
      :plan_order,
      :verified_by,
      :domain
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
      "claimed",
      "completed",
      "archived"
    ])
    |> validate_inclusion(:priority, ["low", "normal", "high", "urgent"])
  end
end

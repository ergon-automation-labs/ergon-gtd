defmodule BotArmyGtd.Schemas.Plan do
  @moduledoc """
  Ecto schema for GTD plans.

  Plans represent high-level goals that are decomposed into ordered subtasks.
  Each plan tracks the decomposition process, task execution, and completion status.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "plans" do
    field(:goal, :string)
    field(:context, :map)
    field(:constraints, :map)
    field(:status, :string, default: "planning")
    field(:generated_by, :string, default: "llm_decomposer")
    field(:decomposition_model, :string, default: "gpt4")
    field(:result, :map)
    field(:notify_via_subject, :string)
    field(:metadata, :map, default: %{})
    field(:started_at, :naive_datetime)
    field(:completed_at, :naive_datetime)
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)

    has_many(:tasks, BotArmyGtd.Schemas.Task, foreign_key: :plan_id)

    timestamps()
  end

  @doc false
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :goal,
      :context,
      :constraints,
      :status,
      :generated_by,
      :decomposition_model,
      :result,
      :notify_via_subject,
      :metadata,
      :started_at,
      :completed_at,
      :tenant_id,
      :user_id
    ])
    |> validate_required([:goal, :tenant_id, :user_id])
    |> validate_inclusion(:status, ["planning", "executing", "completed", "failed", "cancelled"])
  end
end

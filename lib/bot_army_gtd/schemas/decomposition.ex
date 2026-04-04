defmodule BotArmyGtd.Schemas.Decomposition do
  @moduledoc """
  Ecto schema for task decompositions.

  Stores task decomposition results from multi-step LLM chain inference.
  Designed with future learning system integration in mind (Phase 3+).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "decompositions" do
    field :parent_task_id, Ecto.UUID
    field :status, :string, default: "in_progress"
    field :tenant_id, Ecto.UUID
    field :user_id, Ecto.UUID

    # Steps and outputs (Phase 2)
    field :step_outputs, {:array, :map}, default: []
    field :subtask_list, :map
    field :effort_estimates, :map
    field :dependencies, :map

    # FSRS fields for future learning (Phase 3+)
    field :stability, :float, default: 0.0
    field :difficulty, :float, default: 0.0
    field :due_at, :utc_datetime
    field :review_count, :integer, default: 0
    field :last_grade, :integer

    # Predicted vs actual tracking (Phase 3+)
    field :predicted_subtask_count, :integer
    field :predicted_total_effort_hours, :float
    field :actual_subtask_count, :integer
    field :actual_total_effort_hours, :float
    field :missing_subtasks, {:array, :string}, default: []
    field :extra_subtasks, {:array, :string}, default: []

    # User feedback (Phase 3+)
    field :user_rating, :integer
    field :user_feedback, :string
    field :confidence_grade, :integer

    # Extensibility for Phase 3+
    field :review_queue_id, Ecto.UUID

    # Metadata for learning (Phase 3+)
    field :source_domain, :string
    field :source_complexity_estimate, :string
    field :decomposition_timestamp, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(decomposition, attrs) do
    decomposition
    |> cast(attrs, [
      :parent_task_id,
      :status,
      :tenant_id,
      :user_id,
      :step_outputs,
      :subtask_list,
      :effort_estimates,
      :dependencies,
      :stability,
      :difficulty,
      :due_at,
      :review_count,
      :last_grade,
      :predicted_subtask_count,
      :predicted_total_effort_hours,
      :actual_subtask_count,
      :actual_total_effort_hours,
      :missing_subtasks,
      :extra_subtasks,
      :user_rating,
      :user_feedback,
      :confidence_grade,
      :review_queue_id,
      :source_domain,
      :source_complexity_estimate,
      :decomposition_timestamp
    ])
    |> validate_required([:parent_task_id, :status])
    |> validate_inclusion(:status, ["in_progress", "completed", "failed", "reviewed"])
  end
end

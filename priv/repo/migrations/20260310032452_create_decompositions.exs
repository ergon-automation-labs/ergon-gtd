defmodule BotArmyGtd.Repo.Migrations.CreateDecompositions do
  use Ecto.Migration

  def change do
    create table(:decompositions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:parent_task_id, :uuid, null: false)

      # Steps and outputs (Phase 2)
      add(:step_outputs, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:subtask_list, :jsonb)
      add(:effort_estimates, :jsonb)
      add(:dependencies, :jsonb)

      # Status tracking
      add(:status, :string, null: false, default: "in_progress")

      # FSRS fields for future learning (Phase 3+, bake in now)
      add(:stability, :float, default: 0.0)
      add(:difficulty, :float, default: 0.0)
      add(:due_at, :utc_datetime)
      add(:review_count, :integer, default: 0)
      add(:last_grade, :integer)

      # Predicted vs actual tracking (Phase 3+)
      add(:predicted_subtask_count, :integer)
      add(:predicted_total_effort_hours, :float)
      add(:actual_subtask_count, :integer)
      add(:actual_total_effort_hours, :float)
      add(:missing_subtasks, {:array, :string}, default: fragment("'{}'::text[]"))
      add(:extra_subtasks, {:array, :string}, default: fragment("'{}'::text[]"))

      # User feedback (Phase 3+)
      add(:user_rating, :integer)
      add(:user_feedback, :text)
      add(:confidence_grade, :integer)

      # Extensibility for Phase 3+
      add(:review_queue_id, :uuid)

      # Multitenancy
      add(:tenant_id, :uuid, null: false)
      add(:user_id, :uuid, null: false)

      # Metadata for learning (Phase 3+)
      add(:source_domain, :string)
      add(:source_complexity_estimate, :string)
      add(:decomposition_timestamp, :utc_datetime)

      timestamps()
    end

    create(index(:decompositions, [:parent_task_id]))
    create(index(:decompositions, [:status]))
    create(index(:decompositions, [:user_rating]))
    create(index(:decompositions, [:tenant_id]))
    create(index(:decompositions, [:user_id]))
  end
end

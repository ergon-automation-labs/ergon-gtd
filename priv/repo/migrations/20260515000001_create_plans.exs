defmodule BotArmyGtd.Repo.Migrations.CreatePlans do
  use Ecto.Migration

  def change do
    # Create plans table
    create table(:plans, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)
      add(:user_id, :uuid, null: false)
      add(:goal, :text, null: false)
      add(:context, :map)
      add(:constraints, :map)
      add(:status, :string, null: false, default: "planning")
      add(:generated_by, :string, default: "llm_decomposer")
      add(:decomposition_model, :string, default: "gpt4")
      add(:result, :map)
      add(:notify_via_subject, :string)
      add(:metadata, :map, default: %{})
      add(:started_at, :naive_datetime)
      add(:completed_at, :naive_datetime)
      add(:inserted_at, :naive_datetime, null: false)
      add(:updated_at, :naive_datetime, null: false)
    end

    create(index(:plans, [:tenant_id, :status]))
    create(index(:plans, [:user_id, :status]))
    create(index(:plans, [:inserted_at]))

    # Modify tasks table to add plan-related columns
    alter table(:tasks) do
      add(:generated_by_ai, :boolean, default: false)
      add(:plan_id, references(:plans, type: :uuid, on_delete: :delete_all))
      add(:plan_order, :integer)
      add(:verified_by, :string)
    end

    create(index(:tasks, [:plan_id, :plan_order]))

    # Add check constraint: if plan_id is set, plan_order must be set
    execute("""
    ALTER TABLE tasks ADD CONSTRAINT check_plan_order_if_plan CHECK (
      (plan_id IS NULL AND plan_order IS NULL) OR
      (plan_id IS NOT NULL AND plan_order IS NOT NULL)
    )
    """)
  end
end

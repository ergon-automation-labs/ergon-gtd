defmodule BotArmyGtd.Repo.Migrations.AddSubtasksAndLabelsToTasks do
  use Ecto.Migration

  def up do
    # Add parent_task_id for task hierarchies (subtasks)
    alter table(:tasks) do
      add(:parent_task_id, :uuid)
    end

    create(index(:tasks, [:parent_task_id]))

    # Add labels as an array for filtering and categorization
    alter table(:tasks) do
      add(:labels, {:array, :string}, default: [])
    end

    # Add index for labels filtering (using GIN index)
    execute("CREATE INDEX IF NOT EXISTS tasks_labels_idx ON tasks USING gin(labels)")
  end

  def down do
    # Drop labels index and column
    execute("DROP INDEX IF EXISTS tasks_labels_idx")

    alter table(:tasks) do
      remove(:labels, {:array, :string})
    end

    # Drop parent_task_id index and column
    drop(index(:tasks, [:parent_task_id]))

    alter table(:tasks) do
      remove(:parent_task_id, :uuid)
    end
  end
end

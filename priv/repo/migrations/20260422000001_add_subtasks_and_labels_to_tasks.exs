defmodule BotArmyGtd.Repo.Migrations.AddSubtasksAndLabelsToTasks do
  use Ecto.Migration

  def change do
    # Add parent_task_id for task hierarchies (subtasks)
    add(:parent_task_id, :uuid)

    create(index(:tasks, [:parent_task_id]))

    # Add labels as an array for filtering and categorization
    add(:labels, {:array, :string}, default: [])

    # Add index for labels filtering
    create(index(:tasks, ["labels"], using: :gin))
  end
end

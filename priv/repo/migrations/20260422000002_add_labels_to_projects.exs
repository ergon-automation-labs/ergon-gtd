defmodule BotArmyGtd.Repo.Migrations.AddLabelsToProjects do
  use Ecto.Migration

  def up do
    # Add labels as an array for filtering and categorization
    alter table(:projects) do
      add(:labels, {:array, :string}, default: [])
    end

    # Add index for labels filtering (using GIN index)
    execute("CREATE INDEX IF NOT EXISTS projects_labels_idx ON projects USING gin(labels)")
  end

  def down do
    # Drop labels index and column
    execute("DROP INDEX IF EXISTS projects_labels_idx")

    alter table(:projects) do
      remove(:labels, {:array, :string})
    end
  end
end

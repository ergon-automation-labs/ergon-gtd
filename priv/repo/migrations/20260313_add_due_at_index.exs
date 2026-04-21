defmodule BotArmyGtd.Repo.Migrations.AddDueAtIndex do
  use Ecto.Migration
  import Ecto.Migration, only: [table_exists?: 1]
  require Logger

  def up do
    # Add index on due_at for efficient queries in ReviewScheduler
    # Queries: decompositions with status="completed" and due_at <= now

    # Check if table exists first (handles case where migrations ran out of order)
    if table_exists?(:decompositions) do
      create(index(:decompositions, [:due_at]))

      # Composite index for optimized filtering by status and due_at
      create(index(:decompositions, [:status, :due_at]))
    else
      Logger.info("Skipping add_due_at_index - decompositions table not yet created")
    end
  end

  def down do
    # Only drop if table exists
    if table_exists?(:decompositions) do
      drop(index(:decompositions, [:due_at]))
      drop(index(:decompositions, [:status, :due_at]))
    end
  end
end

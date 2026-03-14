defmodule BotArmyGtd.Repo.Migrations.AddDueAtIndex do
  use Ecto.Migration

  def change do
    # Add index on due_at for efficient queries in ReviewScheduler
    # Queries: decompositions with status="completed" and due_at <= now
    create index(:decompositions, [:due_at])

    # Composite index for optimized filtering by status and due_at
    create index(:decompositions, [:status, :due_at])
  end
end

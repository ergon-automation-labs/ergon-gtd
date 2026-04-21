defmodule BotArmyGtd.Repo.Migrations.AddDueAtIndex do
  use Ecto.Migration

  def change do
    create(index(:decompositions, [:due_at]))
    create(index(:decompositions, [:status, :due_at]))
  end
end

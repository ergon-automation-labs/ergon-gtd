defmodule BotArmyGtd.Repo.Migrations.AddDueAtIndex do
  use Ecto.Migration

  def change do
    if table_exists?(:decompositions) do
      create(index(:decompositions, [:due_at]))
      create(index(:decompositions, [:status, :due_at]))
    else
      Logger.info("Skipping add_due_at_index - decompositions table not yet created")
    end
  end
end

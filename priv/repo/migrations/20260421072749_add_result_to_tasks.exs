defmodule BotArmyGtd.Repo.Migrations.AddResultToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:result, :map)
    end
  end
end

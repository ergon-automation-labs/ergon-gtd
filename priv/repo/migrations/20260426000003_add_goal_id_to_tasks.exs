defmodule BotArmyGtd.Repo.Migrations.AddGoalIdToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:goal_id, :string)
    end

    create(index(:tasks, [:goal_id]))
  end
end

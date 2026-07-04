defmodule BotArmyGtd.Repo.Migrations.AddVerificationToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:verification, :map, default: nil, null: true)
    end
  end
end

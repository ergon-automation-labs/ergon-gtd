defmodule BotArmyGtd.Repo.Migrations.AddDomainToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:domain, :string)
    end

    create(index(:tasks, [:domain]))
  end
end

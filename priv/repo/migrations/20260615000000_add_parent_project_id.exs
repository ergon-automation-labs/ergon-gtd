defmodule BotArmyGtd.Repo.Migrations.AddParentProjectId do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:parent_project_id, :uuid, null: true)
    end

    create(index(:projects, [:parent_project_id]))
  end
end

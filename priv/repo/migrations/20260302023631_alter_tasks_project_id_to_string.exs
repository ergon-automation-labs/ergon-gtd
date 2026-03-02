defmodule BotArmyGtd.Repo.Migrations.AlterTasksProjectIdToString do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE tasks DROP CONSTRAINT tasks_project_id_fkey",
      "ALTER TABLE tasks ADD CONSTRAINT tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE RESTRICT"
    )
    alter table(:tasks) do
      modify :project_id, :string
    end
  end
end

defmodule BotArmyGtd.Repo.Migrations.AddBreadcrumbsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :breadcrumbs, :jsonb, default: "[]"
    end
  end
end

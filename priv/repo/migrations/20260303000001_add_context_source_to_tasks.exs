defmodule BotArmyGtd.Repo.Migrations.AddContextSourceToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :context, :string, comment: "Context tag (@phone, @computer, @errands, etc.)"
      add :source, :string, default: "user", comment: "Source of task (user, job_bot, chore_bot, etc.)"
      add :source_metadata, :map, comment: "JSONB metadata from source system"
    end

    create index(:tasks, [:context])
    create index(:tasks, [:source])
  end
end

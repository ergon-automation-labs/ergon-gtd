defmodule BotArmyGtd.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :status, :string, default: "active", null: false
      add :area, :string

      timestamps()
    end

    create index(:projects, [:status])
  end
end

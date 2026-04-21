defmodule BotArmyGtd.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:status, :string, default: "active", null: false)
      add(:priority, :string, default: "normal", null: false)
      add(:due_date, :date)
      add(:completed_at, :naive_datetime)
      add(:project_id, references(:projects, type: :uuid, on_delete: :nilify_all))

      # Multitenancy
      add(:tenant_id, :uuid, null: false)
      add(:user_id, :uuid, null: false)
      add(:context, :string)
      add(:source, :string, null: false, default: "user")
      add(:source_metadata, :map, default: %{})
      add(:result, :map)

      timestamps()
    end

    create(index(:tasks, [:status]))
    create(index(:tasks, [:priority]))
    create(index(:tasks, [:project_id]))
    create(index(:tasks, [:due_date]))
    create(index(:tasks, [:tenant_id]))
    create(index(:tasks, [:user_id]))
  end
end

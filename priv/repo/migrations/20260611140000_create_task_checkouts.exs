defmodule BotArmyGtd.Repo.Migrations.CreateTaskCheckouts do
  use Ecto.Migration

  def up do
    create table(:task_checkouts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:task_id, :uuid, null: false)
      add(:agent_id, :string, null: false)
      add(:agent_type, :string, null: false, default: "unknown")
      add(:checked_out_at, :utc_datetime_usec, null: false)
      add(:checked_in_at, :utc_datetime_usec)
      add(:metadata, :map, default: %{})

      timestamps()
    end

    create(index(:task_checkouts, [:task_id]))
    create(index(:task_checkouts, [:agent_id]))
    create(index(:task_checkouts, [:checked_in_at]))
  end

  def down do
    drop(table(:task_checkouts))
  end
end

defmodule BotArmyGtd.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    # Add tenant_id and user_id to tasks
    alter table(:tasks) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:tasks, [:tenant_id]))
    create(index(:tasks, [:user_id]))
    execute("UPDATE tasks SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL")

    # Add tenant_id and user_id to projects
    alter table(:projects) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:projects, [:tenant_id]))
    create(index(:projects, [:user_id]))

    execute(
      "UPDATE projects SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
    )

    # Add tenant_id and user_id to inbox_items
    alter table(:inbox_items) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:inbox_items, [:tenant_id]))
    create(index(:inbox_items, [:user_id]))

    execute(
      "UPDATE inbox_items SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
    )

    # Add tenant_id and user_id to decompositions
    alter table(:decompositions) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:decompositions, [:tenant_id]))
    create(index(:decompositions, [:user_id]))

    execute(
      "UPDATE decompositions SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
    )
  end

  def down do
    # Drop indexes and columns for tasks
    drop(index(:tasks, [:tenant_id]))
    drop(index(:tasks, [:user_id]))

    alter table(:tasks) do
      remove(:tenant_id)
      remove(:user_id)
    end

    # Drop indexes and columns for projects
    drop(index(:projects, [:tenant_id]))
    drop(index(:projects, [:user_id]))

    alter table(:projects) do
      remove(:tenant_id)
      remove(:user_id)
    end

    # Drop indexes and columns for inbox_items
    drop(index(:inbox_items, [:tenant_id]))
    drop(index(:inbox_items, [:user_id]))

    alter table(:inbox_items) do
      remove(:tenant_id)
      remove(:user_id)
    end

    # Drop indexes and columns for decompositions
    drop(index(:decompositions, [:tenant_id]))
    drop(index(:decompositions, [:user_id]))

    alter table(:decompositions) do
      remove(:tenant_id)
      remove(:user_id)
    end
  end
end

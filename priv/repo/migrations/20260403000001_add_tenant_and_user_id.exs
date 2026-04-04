defmodule BotArmyGTD.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    # projects table
    alter table(:projects) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:projects, [:tenant_id])
    create index(:projects, [:user_id])

    # tasks table
    alter table(:tasks) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:tasks, [:tenant_id])
    create index(:tasks, [:user_id])

    # inbox_items table
    alter table(:inbox_items) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:inbox_items, [:tenant_id])
    create index(:inbox_items, [:user_id])

    # decompositions table
    alter table(:decompositions) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:decompositions, [:tenant_id])
    create index(:decompositions, [:user_id])

    # log_entries table
    alter table(:log_entries) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:log_entries, [:tenant_id])
    create index(:log_entries, [:user_id])

    # Backfill all rows with default tenant UUID
    default_tenant_id = "00000000-0000-0000-0000-000000000001"
    execute("""
    UPDATE projects SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE tasks SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE inbox_items SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE decompositions SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE log_entries SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
  end

  def down do
    # projects table
    drop index(:projects, [:tenant_id])
    drop index(:projects, [:user_id])
    alter table(:projects) do
      remove :tenant_id
      remove :user_id
    end

    # tasks table
    drop index(:tasks, [:tenant_id])
    drop index(:tasks, [:user_id])
    alter table(:tasks) do
      remove :tenant_id
      remove :user_id
    end

    # inbox_items table
    drop index(:inbox_items, [:tenant_id])
    drop index(:inbox_items, [:user_id])
    alter table(:inbox_items) do
      remove :tenant_id
      remove :user_id
    end

    # decompositions table
    drop index(:decompositions, [:tenant_id])
    drop index(:decompositions, [:user_id])
    alter table(:decompositions) do
      remove :tenant_id
      remove :user_id
    end

    # log_entries table
    drop index(:log_entries, [:tenant_id])
    drop index(:log_entries, [:user_id])
    alter table(:log_entries) do
      remove :tenant_id
      remove :user_id
    end
  end
end

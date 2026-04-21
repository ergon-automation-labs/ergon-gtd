defmodule BotArmyGtd.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration

  def change do
    for table <- [:projects, :tasks, :inbox_items, :decompositions, :log_entries] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id SET NOT NULL")
    end
  end

  def down do
    for table <- [:projects, :tasks, :inbox_items, :decompositions, :log_entries] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id DROP NOT NULL")
    end
  end
end

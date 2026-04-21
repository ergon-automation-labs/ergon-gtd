defmodule BotArmyGtd.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration
  import Ecto.Migration, only: [table_exists?: 1]
  require Logger

  def up do
    for table <- [:projects, :tasks, :inbox_items, :decompositions, :log_entries] do
      if table_exists?(table) do
        execute("ALTER TABLE #{table} ALTER COLUMN tenant_id SET NOT NULL")
        Logger.info("Enabled NOT NULL constraint on #{table}.tenant_id")
      else
        Logger.info("Skipping #{table}.tenant_id - table not yet created")
      end
    end
  end

  def down do
    for table <- [:projects, :tasks, :inbox_items, :decompositions, :log_entries] do
      if table_exists?(table) do
        execute("ALTER TABLE #{table} ALTER COLUMN tenant_id DROP NOT NULL")
      end
    end
  end
end

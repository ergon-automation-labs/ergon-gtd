defmodule BotArmyGtd.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration

  def up do
    for table <- [:tasks, :projects, :inbox_items, :decompositions] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id SET NOT NULL")
      execute("ALTER TABLE #{table} ALTER COLUMN user_id SET NOT NULL")
    end
  end

  def down do
    for table <- [:tasks, :projects, :inbox_items, :decompositions] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id DROP NOT NULL")
      execute("ALTER TABLE #{table} ALTER COLUMN user_id DROP NOT NULL")
    end
  end
end

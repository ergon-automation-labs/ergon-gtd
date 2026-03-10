import Config

# Test configuration uses mocks instead of real database stores
config :bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock
config :bot_army_gtd, :project_store, BotArmyGtd.ProjectStoreMock
config :bot_army_gtd, :inbox_item_store, BotArmyGtd.InboxItemStoreMock
config :bot_army_gtd, :decomposition_store, BotArmyGtd.DecompositionStoreMock

# Test against Kubernetes PostgreSQL (via NodePort)
# Uses same configuration as production, just with test database
config :bot_army_gtd, BotArmyGtd.Repo,
  database: System.get_env("BOT_ARMY_GTD_DB_NAME", "bot_army_gtd_test"),
  hostname: System.get_env("BOT_ARMY_GTD_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_GTD_DB_PORT", "5432")),
  username: System.get_env("BOT_ARMY_GTD_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_GTD_DB_PASSWORD", "postgres"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

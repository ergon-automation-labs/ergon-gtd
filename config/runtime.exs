import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

# Auto-start bot_army_runtime services (Registry, NATS connection, etc.)
# This is needed when starting the application manually (not via supervisor)
config :bot_army_runtime, :auto_start_services, true

# Database configuration at runtime
# Priority: BOT_ARMY_GTD_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
config :bot_army_gtd, BotArmyGtd.Repo,
  database:
    System.get_env("BOT_ARMY_GTD_DB_NAME") || System.get_env("DATABASE_NAME") || "ergon_gtd",
  hostname:
    System.get_env("BOT_ARMY_GTD_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_GTD_DB_PORT") || System.get_env("DATABASE_PORT") || "30003"
    ),
  username:
    System.get_env("BOT_ARMY_GTD_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password:
    System.get_env("BOT_ARMY_GTD_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") ||
      "postgres",
  pool_size: 3,
  ssl: false

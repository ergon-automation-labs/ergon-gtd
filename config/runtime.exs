import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

# Auto-start bot_army_library_runtime services (Registry, NATS connection, etc.)
# This is needed when starting the application manually (not via supervisor)
config :bot_army_library_runtime, :auto_start_services, true

# Keep test traffic isolated from shared dev/prod NATS.
nats_host = System.get_env("NATS_HOST", "localhost")

nats_port =
  if config_env() == :test do
    4223
  else
    String.to_integer(System.get_env("NATS_PORT", "4223"))
  end

config :bot_army_library_runtime, :nats,
  servers: [{nats_host, nats_port}],
  ping_interval: 5000,
  max_reconnect_attempts: 3,
  reconnect_delay_ms: 100

# Guard against accidental test fixture/event pollution by default.
# Set GTD_REJECT_TEST_DATA=false to disable if needed.
reject_test_data =
  System.get_env("GTD_REJECT_TEST_DATA", "true")
  |> String.downcase()
  |> then(&(&1 in ["1", "true", "yes", "on"]))

config :bot_army_gtd, :reject_test_data, reject_test_data

# Database configuration at runtime
# Priority: BOT_ARMY_GTD_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
config :bot_army_gtd, BotArmyGtd.Repo,
  database:
    System.get_env("BOT_ARMY_GTD_DB_NAME") || System.get_env("DATABASE_NAME") || "ergon_gtd",
  hostname:
    System.get_env("BOT_ARMY_GTD_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_GTD_DB_PORT") || System.get_env("DATABASE_PORT") || "30006"
    ),
  username:
    System.get_env("BOT_ARMY_GTD_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password:
    System.get_env("BOT_ARMY_GTD_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") ||
      "postgres",
  pool_size: System.get_env("BOT_POOL_SIZE", "20") |> String.to_integer(),
  ssl: false

# Learning library configuration (uses same database as this bot)
config :bot_army_library_learning, ecto_repos: [BotArmyLearning.Repo]

config :bot_army_library_learning, BotArmyLearning.Repo,
  database:
    System.get_env("BOT_ARMY_GTD_DB_NAME") || System.get_env("DATABASE_NAME") || "ergon_gtd",
  hostname:
    System.get_env("BOT_ARMY_GTD_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_GTD_DB_PORT") || System.get_env("DATABASE_PORT") || "30006"
    ),
  username:
    System.get_env("BOT_ARMY_GTD_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password:
    System.get_env("BOT_ARMY_GTD_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") ||
      "postgres",
  pool_size: System.get_env("BOT_POOL_SIZE", "20") |> String.to_integer(),
  ssl: false

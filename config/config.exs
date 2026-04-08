import Config

# Load .env file for local development/testing
if File.exists?(".env") do
  File.stream!(".env")
  |> Stream.map(&String.trim_trailing/1)
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Stream.reject(&(&1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> nil
    end
  end)
end

# Ecto repositories for migrations
config :bot_army_gtd, ecto_repos: [BotArmyGtd.Repo]

# ReviewScheduler: Periodic discovery of decompositions due for review
config :bot_army_gtd, BotArmyGtd.ReviewScheduler,
  enabled: true,
  interval_seconds: 300  # Every 5 minutes

# Database configuration — defaults only, overridden by config/runtime.exs at startup
config :bot_army_gtd, BotArmyGtd.Repo,
  database: "ergon_gtd",
  hostname: "localhost",
  port: 30003,
  username: "postgres",
  password: "postgres",
  pool_size: 10

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end

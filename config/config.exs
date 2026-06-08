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
  # Every 5 minutes
  interval_seconds: 300

# ScoreScheduler: Periodic recomputation of item scores for "what's next" ranking
config :bot_army_gtd, BotArmyGtd.ScoreScheduler,
  enabled: true,
  # Every 5 minutes
  interval_seconds: 300

# Deployment status for registry reporting
config :bot_army_gtd, :deployment_status, "deployed"

# Intent thresholds for autonomous heartbeat decisions
config :bot_army_gtd, :intent_thresholds, %{
  stale_task_count: %{min: 3, weight: 0.6},
  idle_minutes: %{min: 30, weight: 0.3},
  random_threshold: 0.5
}

# Database configuration — defaults only, overridden by config/runtime.exs at startup
config :bot_army_gtd, BotArmyGtd.Repo,
  database: "ergon_gtd",
  hostname: "localhost",
  port: 30003,
  username: "postgres",
  password: "postgres",
  pool_size: 10

# Logger with correlation_id + bot-specific metadata
config :logger,
  level: :info,
  backends: [:console],
  default_formatter:
    {BotArmyRuntime.LoggerFormatter,
     [
       :action,
       :score,
       :reason,
       :item_type,
       :item_id,
       :error,
       :template,
       :goal,
       :subject,
       :timeout_ms,
       :strategy,
       :method,
       :subtask_count
     ]}

config :logger, :console,
  format:
    {BotArmyRuntime.LoggerFormatter,
     [
       :action,
       :score,
       :reason,
       :item_type,
       :item_id,
       :error,
       :template,
       :goal,
       :subject,
       :timeout_ms,
       :strategy,
       :method,
       :subtask_count
     ]},
  metadata: [
    :correlation_id,
    :action,
    :score,
    :reason,
    :item_type,
    :item_id,
    :error,
    :template,
    :goal,
    :subject,
    :timeout_ms,
    :strategy,
    :method,
    :subtask_count
  ]

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end

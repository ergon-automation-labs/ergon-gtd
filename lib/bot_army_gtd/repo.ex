defmodule BotArmyGtd.Repo do
  @moduledoc """
  Ecto Repository for the GTD bot.

  Provides database access for tasks and projects with PostgreSQL backend.
  All queries automatically pass through the database circuit breaker to prevent
  hammering the database during outages.
  """

  use BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo,
    otp_app: :bot_army_gtd,
    adapter: Ecto.Adapters.Postgres
end

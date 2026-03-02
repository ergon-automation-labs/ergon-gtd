defmodule BotArmyGtd.Repo do
  @moduledoc """
  Ecto Repository for the GTD bot.

  Provides database access for tasks and projects with PostgreSQL backend.
  """

  use Ecto.Repo,
    otp_app: :bot_army_gtd,
    adapter: Ecto.Adapters.Postgres
end

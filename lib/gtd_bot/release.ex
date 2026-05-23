defmodule GtdBot.Release do
  @moduledoc """
  Release tasks for the GTD bot.

  Migrations are run via the shared BotArmyRuntime.Ecto.MigrationRunner:

      /path/to/gtd_bot/bin/gtd_bot eval 'GtdBot.Release.migrate()'

  Called from Salt during bot deployment, before the bot starts.
  """

  alias BotArmyRuntime.Ecto.MigrationRunner

  @app :bot_army_gtd

  def migrate do
    MigrationRunner.run(
      repo_module: GtdBot.Repo,
      app_module: @app
    )
  end
end

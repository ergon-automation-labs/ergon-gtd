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
      repo_module: BotArmyGtd.Repo,
      app_module: @app
    )

    # Also run aggregator migrations
    run_aggregator_migrations()
  end

  defp run_aggregator_migrations do
    load_app(:bot_army_aggregator)

    case Ecto.Migrator.run(GtdBot.Repo, aggregator_migrations_path(), :up, all: true) do
      {:ok, _migrations, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp aggregator_migrations_path do
    :bot_army_aggregator
    |> Application.app_dir("priv/repo/migrations")
  end

  defp load_app(app) do
    Application.load(app)
  end
end

defmodule BotArmyGtd.Application do
  @moduledoc """
  BotArmyGtd application supervisor.

  Manages GTD bot services:
  - NATS message consumer
  - Event handlers
  - Task processing pipeline
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database connection
      BotArmyGtd.Repo,

      # Task and project storage
      {BotArmyGtd.TaskStore, []},
      {BotArmyGtd.ProjectStore, []},

      # NATS connection and consumer
      {BotArmyGtd.NATS.Consumer, []}
    ]

    opts = [strategy: :one_for_one, name: BotArmyGtd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

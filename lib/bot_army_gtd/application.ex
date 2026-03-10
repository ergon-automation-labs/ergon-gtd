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
    children = []
    |> maybe_add_repo()
    |> maybe_add_nats_connection()
    |> maybe_add_task_store()
    |> maybe_add_project_store()
    |> maybe_add_inbox_item_store()
    |> maybe_add_consumer()

    opts = [strategy: :one_for_one, name: BotArmyGtd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if Mix.env() == :test, do: children, else: [BotArmyGtd.Repo | children]
  end

  defp maybe_add_nats_connection(children) do
    if Mix.env() == :test, do: children, else: [{BotArmyRuntime.NATS.Connection, []} | children]
  end

  defp maybe_add_task_store(children) do
    if Application.get_env(:bot_army_gtd, :task_store) == BotArmyGtd.TaskStore do
      [{BotArmyGtd.TaskStore, []} | children]
    else
      children
    end
  end

  defp maybe_add_project_store(children) do
    if Application.get_env(:bot_army_gtd, :project_store) == BotArmyGtd.ProjectStore do
      [{BotArmyGtd.ProjectStore, []} | children]
    else
      children
    end
  end

  defp maybe_add_inbox_item_store(children) do
    if Application.get_env(:bot_army_gtd, :inbox_item_store) == BotArmyGtd.InboxItemStore do
      [{BotArmyGtd.InboxItemStore, []} | children]
    else
      children
    end
  end

  defp maybe_add_consumer(children) do
    if Mix.env() == :test, do: children, else: [{BotArmyGtd.NATS.Consumer, []} | children]
  end
end

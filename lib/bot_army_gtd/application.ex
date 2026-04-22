defmodule BotArmyGtd.Application do
  @moduledoc """
  BotArmyGtd application supervisor.

  Manages GTD bot services:
  - NATS message consumer
  - Event handlers
  - Task processing pipeline
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_repo()
      |> maybe_add_task_store()
      |> maybe_add_project_store()
      |> maybe_add_inbox_item_store()
      |> maybe_add_decomposition_store()
      |> maybe_add_log_entry_store()
      |> maybe_add_review_scheduler()
      |> maybe_add_consumer()
      |> maybe_add_health_responder()

    opts = [strategy: :one_for_one, name: BotArmyGtd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test, do: children, else: [BotArmyGtd.Repo | children]
  end

  defp maybe_add_task_store(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.TaskStore, []} | children]
  end

  defp maybe_add_project_store(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.ProjectStore, []} | children]
  end

  defp maybe_add_inbox_item_store(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.InboxItemStore, []} | children]
  end

  defp maybe_add_decomposition_store(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.DecompositionStore, []} | children]
  end

  defp maybe_add_log_entry_store(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.LogEntryStore, []} | children]
  end

  defp maybe_add_review_scheduler(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.ReviewScheduler, []} | children]
  end

  defp maybe_add_consumer(children) do
    if @env == :test, do: children, else: [{BotArmyGtd.NATS.Consumer, []} | children]
  end

  defp maybe_add_health_responder(children) do
    if @env == :test,
      do: children,
      else: [
        {BotArmyGtd.HealthResponder, [bot_name: :gtd, repo: BotArmyGtd.Repo, version: "0.3.0"]},
        {BotArmyRuntime.Health.Monitor, []} | children
      ]
  end
end

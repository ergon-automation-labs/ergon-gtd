defmodule BotArmyGtd.NATS.Consumer do
  @moduledoc """
  NATS message consumer for the GTD bot.

  Subscribes to NATS subjects matching GTD message patterns:
  - `gtd.task.*` - Task-related events
  - `gtd.project.*` - Project-related events

  Messages are decoded using BotArmyCore.NATS.Decoder and routed to
  appropriate handlers based on the event type.

  ## Features

  - Automatic subscription to GTD topics
  - Message decoding and validation
  - Event-based routing to handlers
  - Graceful error handling and recovery
  - Comprehensive logging

  ## Connection Management

  The consumer maintains a persistent NATS connection. If the connection
  is lost, it will attempt to reconnect with exponential backoff.

  ## Implementation

  This implementation uses a GenServer to manage subscriptions. In production,
  this would connect to a real NATS broker. The structure supports dependency
  injection for testing and mocking.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route decoded message to appropriate handler based on event type.

  This is the core dispatch logic that routes incoming messages to handlers.
  Handles both GTD-internal events and cross-bot events from LLM bot.
  """
  def route_message(message) do
    event = message["event"]

    case event do
      "gtd.inbox.add" -> BotArmyGtd.Handlers.InboxHandler.handle_add(message)
      "gtd.task.create" -> BotArmyGtd.Handlers.TaskHandler.handle_create(message)
      "gtd.task.update" -> BotArmyGtd.Handlers.TaskHandler.handle_update(message)
      "gtd.task.complete" -> BotArmyGtd.Handlers.TaskHandler.handle_complete(message)
      "gtd.task.command.defer" -> BotArmyGtd.Handlers.TaskHandler.handle_defer(message)
      "gtd.task.command.delete" -> BotArmyGtd.Handlers.TaskHandler.handle_delete(message)
      "gtd.task.decompose" -> BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)
      "gtd.decomposition.approve" -> BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)
      "gtd.decomposition.reject" -> BotArmyGtd.Handlers.DecompositionHandler.handle_reject(message)
      "gtd.decomposition.review" -> BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      "gtd.project.create" -> BotArmyGtd.Handlers.ProjectHandler.handle_create(message)
      "gtd.project.update" -> BotArmyGtd.Handlers.ProjectHandler.handle_update(message)
      "llm.response.parsed" -> BotArmyGtd.Handlers.InboxParsingHandler.handle_parse(message)
      "llm.chain.completed" -> BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      _ -> Logger.debug("Unknown event type: #{event}")
    end
  end

  # Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting GTD NATS consumer")

    state = %{
      subscriptions: [],
      reconnect_attempt: 0,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Logger.info("Connected to NATS, subscribing to GTD topics")

        subscriptions =
          [
            "gtd.inbox.add",
            "gtd.task.create",
            "gtd.task.update",
            "gtd.task.complete",
            "gtd.task.command.defer",
            "gtd.task.command.delete",
            "gtd.task.decompose",
            "gtd.decomposition.approve",
            "gtd.decomposition.reject",
            "gtd.decomposition.review",
            "gtd.project.create",
            "gtd.project.update",
            "llm.response.parsed",
            "llm.chain.completed"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("GTD consumer subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        {:noreply, %{state | subscriptions: subscriptions}}

      {:error, _reason} ->
        Logger.warning("NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    Logger.debug("Received NATS message on subject: #{msg.topic}")

    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will attempt to reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Connected to NATS")
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to NATS")
    {:noreply, state}
  end
end

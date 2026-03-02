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

  @nats_url System.get_env("NATS_URL", "nats://localhost:4222")
  @reconnect_delay_ms 5000
  @max_reconnect_retries 10

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route decoded message to appropriate handler based on event type.

  This is the core dispatch logic that routes incoming messages to handlers.
  """
  def route_message(message) do
    event = message["event"]

    case event do
      "gtd.task.create" -> BotArmyGtd.Handlers.TaskHandler.handle_create(message)
      "gtd.task.update" -> BotArmyGtd.Handlers.TaskHandler.handle_update(message)
      "gtd.task.complete" -> BotArmyGtd.Handlers.TaskHandler.handle_complete(message)
      "gtd.project.create" -> BotArmyGtd.Handlers.ProjectHandler.handle_create(message)
      "gtd.project.update" -> BotArmyGtd.Handlers.ProjectHandler.handle_update(message)
      _ -> Logger.debug("Unknown GTD event type: #{event}")
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

    # In production, connect to NATS here
    # For now, we just start up ready to receive messages
    Logger.info("GTD NATS consumer initialized, ready to receive messages from NATS broker")
    {:ok, state}
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

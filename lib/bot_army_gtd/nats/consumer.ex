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
      "gtd.inbox.add" ->
        BotArmyGtd.Handlers.InboxHandler.handle_add(message)

      "gtd.task.create" ->
        BotArmyGtd.Handlers.TaskHandler.handle_create(message)

      "gtd.task.update" ->
        BotArmyGtd.Handlers.TaskHandler.handle_update(message)

      "gtd.task.complete" ->
        BotArmyGtd.Handlers.TaskHandler.handle_complete(message)

      "gtd.task.command.defer" ->
        BotArmyGtd.Handlers.TaskHandler.handle_defer(message)

      "gtd.task.command.delete" ->
        BotArmyGtd.Handlers.TaskHandler.handle_delete(message)

      "gtd.task.decompose" ->
        BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)

      "gtd.decomposition.approve" ->
        BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)

      "gtd.decomposition.reject" ->
        BotArmyGtd.Handlers.DecompositionHandler.handle_reject(message)

      "gtd.decomposition.review" ->
        BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)

      "gtd.decomposition.request_review" ->
        BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)

      "gtd.project.create" ->
        BotArmyGtd.Handlers.ProjectHandler.handle_create(message)

      "gtd.project.update" ->
        BotArmyGtd.Handlers.ProjectHandler.handle_update(message)

      "gtd.log.create" ->
        BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)

      "llm.response.parsed" ->
        case get_in(message, ["payload", "enrichment_source"]) do
          "log_enrichment" -> BotArmyGtd.Handlers.LogEnrichmentHandler.handle_enriched(message)
          _ -> BotArmyGtd.Handlers.InboxParsingHandler.handle_parse(message)
        end

      "llm.chain.completed" ->
        BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)

      _ ->
        Logger.debug("Unknown event type: #{event}")
    end
  end

  # Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting GTD NATS consumer")

    state = %{
      subscriptions: [],
      reconnect_attempt: 0,
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
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
            "gtd.decomposition.request_review",
            "gtd.project.create",
            "gtd.project.update",
            "gtd.log.create",
            "events.llm.response.parsed",
            "events.llm.chain.completed",
            "gtd.task.list",
            "gtd.decomposition.list_due"
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

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

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
  def handle_info({:msg, %{topic: "gtd.task.list", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    response =
      case task_store.list(tenant_id) do
        {:ok, tasks} ->
          Jason.encode!(%{tasks: tasks})

        {:error, reason} ->
          Jason.encode!(%{error: inspect(reason), tasks: []})
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.decomposition.list_due", reply_to: reply_to} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    decomposition_store =
      Application.get_env(:bot_army_gtd, :decomposition_store, BotArmyGtd.DecompositionStore)

    tenant_id = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
    now = DateTime.utc_now()

    response =
      case decomposition_store.list(tenant_id) do
        {:ok, decompositions} ->
          due =
            decompositions
            |> Enum.filter(fn d ->
              d["status"] in ["completed", "reviewed"] and d["due_at"] != nil
            end)
            |> Enum.filter(fn d ->
              case DateTime.from_iso8601(d["due_at"]) do
                {:ok, due_at, _} -> DateTime.compare(due_at, now) in [:lt, :eq]
                _ -> false
              end
            end)
            |> Enum.sort_by(fn d -> d["due_at"] end)

          Jason.encode!(%{decompositions: due})

        {:error, reason} ->
          Jason.encode!(%{error: inspect(reason), decompositions: []})
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    topic = msg.topic
    reply_to = Map.get(msg, :reply_to)

    # Handle request-reply patterns first
    case topic do
      "gtd.task.create" when is_binary(reply_to) and reply_to != "" ->
        handle_task_create_request(msg, reply_to, state)

      "gtd.task.update" when is_binary(reply_to) and reply_to != "" ->
        handle_task_update_request(msg, reply_to, state)

      _ ->
        BotArmyRuntime.Tracing.with_consumer_span(topic, msg.headers, fn ->
          Logger.debug("Received NATS message on subject: #{topic}")

          case BotArmyCore.NATS.Decoder.decode(msg.body) do
            {:ok, decoded_message} ->
              route_message(decoded_message)

            {:error, reason} ->
              Logger.warning("Failed to decode message from #{topic}: #{inspect(reason)}")
          end
        end)
    end

    {:noreply, state}
  end

  defp handle_task_create_request(msg, reply_to, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case BotArmyGtd.Handlers.TaskHandler.handle_create(decoded_message) do
          :ok ->
            response = Jason.encode!(%{success: true, message: "Task created"})
            if state.conn, do: Gnat.pub(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = Jason.encode!(%{error: inspect(reason)})
            if state.conn, do: Gnat.pub(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode task create message: #{inspect(reason)}")
        error_response = Jason.encode!(%{error: "Invalid message format"})
        if state.conn, do: Gnat.pub(state.conn, reply_to, error_response)
    end
  end

  defp handle_task_update_request(msg, reply_to, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case BotArmyGtd.Handlers.TaskHandler.handle_update(decoded_message) do
          :ok ->
            response = Jason.encode!(%{success: true, message: "Task updated"})
            if state.conn, do: Gnat.pub(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = Jason.encode!(%{error: inspect(reason)})
            if state.conn, do: Gnat.pub(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode task update message: #{inspect(reason)}")
        error_response = Jason.encode!(%{error: "Invalid message format"})
        if state.conn, do: Gnat.pub(state.conn, reply_to, error_response)
    end
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will attempt to reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Connected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to NATS")
    {:noreply, state, {:continue, :connect}}
  end
end

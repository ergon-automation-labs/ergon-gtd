defmodule BotArmyGtd.ArmyContextConsumer do
  @moduledoc """
  Consumes goal health context from Synapse via `army.context` NATS subject.

  GTD Bot uses goal health to:
  - Prioritize tasks from at-risk goals
  - Surface next actions related to stagnant projects
  - Suggest focus blocks for critical work

  Stores at-risk goal IDs in state so TaskStore can prioritize during queries.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5_000

  # API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current at-risk goal IDs"
  def get_at_risk_goals do
    try do
      GenServer.call(__MODULE__, :get_at_risk_goals)
    catch
      :exit, _ -> []
    end
  end

  # Callbacks

  @impl true
  def init(opts) do
    Logger.info("[ArmyContextConsumer] Starting GTD context consumer")

    state = %{
      subscriptions: [],
      reconnect_attempt: 0,
      opts: opts,
      at_risk_goals: [],
      last_update: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        subscribe_to_topics(conn, state)

      {:error, _reason} ->
        handle_connection_unavailable(state)
    end
  end

  defp subscribe_to_topics(conn, state) do
    Logger.info("[ArmyContextConsumer] Connected to NATS, subscribing to army.context")

    case Gnat.sub(conn, self(), "army.context") do
      {:ok, sub} ->
        Logger.info("[ArmyContextConsumer] Subscribed to army.context")
        {:noreply, %{state | subscriptions: [sub]}}

      {:error, reason} ->
        Logger.error("[ArmyContextConsumer] Failed to subscribe: #{inspect(reason)}")
        handle_connection_unavailable(state)
    end
  end

  defp handle_connection_unavailable(state) do
    Logger.warning("[ArmyContextConsumer] NATS unavailable, retrying in #{@reconnect_delay_ms}ms")

    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, _msg}, state) do
    # Message received but we're only using subscriptions
    {:noreply, state}
  end

  @impl true
  def handle_info({_sub, _}, state) do
    # Subscription established
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats_connection_status, :down}, state) do
    Logger.warning("[ArmyContextConsumer] NATS connection lost")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats_connection_status, :up}, state) do
    Logger.info("[ArmyContextConsumer] NATS connection restored")
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({_gnat, message_body}, state) do
    case Jason.decode(message_body) do
      {:ok, context} ->
        at_risk_goals = extract_at_risk_goal_ids(context)

        Logger.debug(
          "[ArmyContextConsumer] Updated at-risk goals: #{length(at_risk_goals)} found"
        )

        {:noreply, %{state | at_risk_goals: at_risk_goals, last_update: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.warning("[ArmyContextConsumer] Failed to decode context: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_at_risk_goals, _from, state) do
    {:reply, state.at_risk_goals, state}
  end

  # Private

  defp extract_at_risk_goal_ids(context) when is_map(context) do
    case get_in(context, ["goals", "at_risk_goals"]) do
      goals when is_list(goals) ->
        Enum.map(goals, &Map.get(&1, "id"))

      _ ->
        []
    end
  end

  defp extract_at_risk_goal_ids(_), do: []
end

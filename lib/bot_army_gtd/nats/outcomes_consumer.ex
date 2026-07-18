defmodule BotArmyGtd.NATS.OutcomesConsumer do
  @moduledoc """
  Subscribes to outcomes.* events from Outcomes Recorder bot and routes them
  to the OutcomesIntegrator handler for task scoring adjustments.

  Subscribed topics:
  - outcomes.task.>
  - outcomes.decomposition.>
  - outcomes.context.>
  """

  use GenServer
  require Logger

  alias BotArmyGtd.Handlers.OutcomesIntegratorHandler

  @reconnect_delay_ms 5000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscriptions: []}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    Logger.info("[OutcomesConsumer] Subscribing to outcomes events")

    topics = [
      "outcomes.task.>",
      "outcomes.decomposition.>",
      "outcomes.context.>"
    ]

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        subscriptions =
          Enum.flat_map(topics, fn topic ->
            try do
              case Gnat.sub(conn, self(), topic) do
                {:ok, sub} ->
                  [{topic, sub}]

                {:error, reason} ->
                  Logger.warning(
                    "[OutcomesConsumer] Failed to subscribe to #{topic}: #{inspect(reason)}"
                  )

                  []
              end
            catch
              :exit, reason ->
                Logger.warning(
                  "[OutcomesConsumer] NATS unavailable for #{topic}: #{inspect(reason)}"
                )

                []
            end
          end)

        if subscriptions == [] do
          Logger.warning(
            "[OutcomesConsumer] No subscriptions active, retrying in #{@reconnect_delay_ms}ms"
          )

          Process.send_after(self(), :retry_subscribe, @reconnect_delay_ms)
        end

        {:noreply, %{state | subscriptions: subscriptions}}

      _ ->
        Logger.warning(
          "[OutcomesConsumer] NATS connection unavailable, retrying in #{@reconnect_delay_ms}ms"
        )

        Process.send_after(self(), :retry_subscribe, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    {:noreply, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_info({:msg, %{body: body, topic: topic}}, state) do
    Task.start(fn -> process_outcomes_event(body, topic) end)
    {:noreply, state}
  end

  defp process_outcomes_event(body, topic) do
    case Jason.decode(body) do
      {:ok, message} ->
        route_to_handler(message, topic)

      {:error, reason} ->
        Logger.warning("[OutcomesConsumer] Failed to decode outcomes event",
          reason: reason,
          topic: topic
        )
    end
  end

  defp route_to_handler(message, topic) do
    case topic do
      "outcomes.task." <> _ ->
        OutcomesIntegratorHandler.handle_task_metrics(message)

      "outcomes.decomposition." <> _ ->
        OutcomesIntegratorHandler.handle_decomposition_metrics(message)

      "outcomes.context." <> _ ->
        OutcomesIntegratorHandler.handle_context_metrics(message)

      _ ->
        Logger.debug("[OutcomesConsumer] Unknown topic, skipping", topic: topic)
    end
  end
end

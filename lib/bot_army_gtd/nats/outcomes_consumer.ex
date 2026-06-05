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

    subscriptions =
      Enum.map(topics, fn topic ->
        {:ok, sub} = Gnat.sub(:nats_connection, self(), topic)
        {topic, sub}
      end)

    {:noreply, %{state | subscriptions: subscriptions}}
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

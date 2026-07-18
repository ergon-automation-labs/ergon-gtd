defmodule BotArmyGtd.NATS.AnomalyAlerter do
  @moduledoc """
  Monitors outcomes metrics and publishes anomaly alerts to Synapse for Discord notification.

  Listens to outcomes.* events and detects:
  - Deep work time drops > 40%
  - Task completion rate crashes > 30%
  - Latency spikes > 50%
  - Mode prediction accuracy drops > 20%

  Publishes alerts via bridge.notification.anomaly for Synapse Discord relay.
  """

  use GenServer
  require Logger

  # Thresholds
  @deep_work_drop_threshold 40.0
  @completion_rate_drop_threshold 30.0
  @latency_spike_threshold 50.0
  @accuracy_drop_threshold 20.0
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
    Logger.info("[AnomalyAlerter] Subscribing to outcomes events")

    topics = [
      "outcomes.task.>",
      "outcomes.decomposition.>",
      "outcomes.context.>",
      "system.health.>"
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
                    "[AnomalyAlerter] Failed to subscribe to #{topic}: #{inspect(reason)}"
                  )

                  []
              end
            catch
              :exit, reason ->
                Logger.warning(
                  "[AnomalyAlerter] NATS unavailable for #{topic}: #{inspect(reason)}"
                )

                []
            end
          end)

        if subscriptions == [] do
          Logger.warning(
            "[AnomalyAlerter] No subscriptions active, retrying in #{@reconnect_delay_ms}ms"
          )

          Process.send_after(self(), :retry_subscribe, @reconnect_delay_ms)
        end

        {:noreply, %{state | subscriptions: subscriptions}}

      _ ->
        Logger.warning(
          "[AnomalyAlerter] NATS connection unavailable, retrying in #{@reconnect_delay_ms}ms"
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
  def handle_info({:msg, %{body: body}}, state) do
    Task.start(fn -> process_metric(body) end)
    {:noreply, state}
  end

  defp process_metric(body) do
    case Jason.decode(body) do
      {:ok, message} ->
        check_for_anomalies(message)

      {:error, reason} ->
        Logger.warning("[AnomalyAlerter] Failed to decode metric",
          reason: reason
        )
    end
  end

  defp check_for_anomalies(message) do
    payload = message["payload"] || %{}
    metric_name = payload["metric_name"]
    value = payload["value"]
    trend_pct = payload["trend_pct"] || 0

    case metric_name do
      "deep_work" when is_number(trend_pct) and trend_pct < -@deep_work_drop_threshold ->
        publish_alert(
          "🚨 Deep Work Drop Detected",
          "Deep work time dropped #{abs(Float.round(trend_pct, 1))}% — consider DND until recovered",
          "deep_work_drop",
          %{
            "metric" => "deep_work",
            "drop_pct" => trend_pct,
            "current_value" => value
          }
        )

      "completion_rate"
      when is_number(trend_pct) and trend_pct < -@completion_rate_drop_threshold ->
        publish_alert(
          "🚨 Completion Rate Crisis",
          "Task completion dropped #{abs(Float.round(trend_pct, 1))}% — check for blockers",
          "completion_rate_drop",
          %{
            "metric" => "completion_rate",
            "drop_pct" => trend_pct,
            "current_value" => value
          }
        )

      "task_latency"
      when is_number(value) and value > 10_000 * (1 + @latency_spike_threshold / 100) ->
        publish_alert(
          "🚨 Latency Spike Detected",
          "Response time spiked to #{Float.round(value, 0)}ms — system may be overloaded",
          "latency_spike",
          %{
            "metric" => "task_latency",
            "latency_ms" => value
          }
        )

      "mode_prediction_accuracy"
      when is_number(trend_pct) and trend_pct < -@accuracy_drop_threshold ->
        publish_alert(
          "⚠️ Mode Prediction Accuracy Declining",
          "Prediction accuracy dropped #{abs(Float.round(trend_pct, 1))}% — behavior patterns shifting",
          "accuracy_drop",
          %{
            "metric" => "mode_prediction_accuracy",
            "drop_pct" => trend_pct,
            "current_value" => value
          }
        )

      _ ->
        :ok
    end
  end

  defp publish_alert(title, description, alert_type, context) do
    alert_payload = %{
      "title" => title,
      "description" => description,
      "alert_type" => alert_type,
      "context" => context,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "severity" => if(alert_type == "completion_rate_drop", do: "critical", else: "warning"),
      "auto_generated" => true
    }

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        case Gnat.pub(conn, "bridge.notification.anomaly", Jason.encode!(alert_payload)) do
          :ok ->
            Logger.info("[AnomalyAlerter] Published anomaly alert",
              type: alert_type,
              title: title
            )

          {:error, reason} ->
            Logger.warning("[AnomalyAlerter] Failed to publish alert",
              reason: reason,
              type: alert_type
            )
        end

      _ ->
        Logger.warning("[AnomalyAlerter] NATS unavailable, cannot publish alert",
          type: alert_type
        )
    end
  end
end

defmodule BotArmyGtd.NATS.WeeklyReportsPublisher do
  @moduledoc """
  Publishes weekly outcomes reports to PARA (Projects/Areas/Resources/Archive).

  Subscribes to outcomes.report.weekly responses and writes generated reports
  to PARA/Projects/Outcomes/ for weekly review.

  This publisher:
  - Listens on outcomes.report.weekly topic
  - Receives weekly markdown reports from Outcomes Recorder bot
  - Writes reports to PARA via para.fs.write NATS subject
  - Logs reports in GTD for reference
  """

  use GenServer
  require Logger

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
    Logger.info("[WeeklyReportsPublisher] Subscribing to outcomes.report.weekly")

    subscriptions =
      try do
        case Gnat.sub(:nats_connection, self(), "outcomes.report.weekly") do
          {:ok, sub} ->
            [{"outcomes.report.weekly", sub}]

          {:error, reason} ->
            Logger.warning("[WeeklyReportsPublisher] Failed to subscribe: #{inspect(reason)}")

            []
        end
      catch
        :exit, reason ->
          Logger.warning("[WeeklyReportsPublisher] NATS unavailable: #{inspect(reason)}")

          []
      end

    if subscriptions == [] do
      Logger.warning(
        "[WeeklyReportsPublisher] No subscription active, retrying in #{@reconnect_delay_ms}ms"
      )

      Process.send_after(self(), :retry_subscribe, @reconnect_delay_ms)
    end

    {:noreply, %{state | subscriptions: subscriptions}}
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    {:noreply, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_info({:msg, %{body: body, topic: topic}}, state) do
    Task.start(fn -> process_report(body, topic) end)
    {:noreply, state}
  end

  defp process_report(body, _topic) do
    case Jason.decode(body) do
      {:ok, message} ->
        publish_to_para(message)

      {:error, reason} ->
        Logger.warning("[WeeklyReportsPublisher] Failed to decode report",
          reason: reason
        )
    end
  end

  defp publish_to_para(%{"data" => report_data}) when is_binary(report_data) do
    case para_publish(report_data) do
      :ok ->
        Logger.info("[WeeklyReportsPublisher] Weekly report published to PARA")

      {:error, reason} ->
        Logger.warning("[WeeklyReportsPublisher] Failed to publish report to PARA",
          reason: reason
        )
    end
  end

  defp publish_to_para(%{"data" => report_data}) when is_map(report_data) do
    markdown = render_report_from_map(report_data)
    publish_to_para(%{"data" => markdown})
  end

  defp publish_to_para(message) do
    Logger.warning("[WeeklyReportsPublisher] Unexpected report format",
      message: inspect(message)
    )
  end

  defp para_publish(report_markdown) do
    today = Date.utc_today()
    filename = "Weekly_Outcomes_#{Date.to_string(today)}"
    folder = "Outcomes"

    payload = %{
      "path" => "#{folder}/#{filename}",
      "content" => report_markdown,
      "format" => "markdown",
      "upsert" => true
    }

    case Gnat.pub(:nats_connection, "para.fs.write", Jason.encode!(payload)) do
      :ok ->
        Logger.debug("[WeeklyReportsPublisher] Published to para.fs.write",
          path: payload["path"]
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_report_from_map(%{
         "period_start" => period_start,
         "period_end" => period_end,
         "metrics" => metrics,
         "anomalies" => anomalies,
         "highlights" => highlights
       }) do
    """
    # 📊 Bot Army Outcomes — Weekly Report

    **Week of**: #{period_start} – #{period_end}

    ## 📈 Metrics

    #{render_metrics(metrics)}

    ## 🚨 Anomalies

    #{render_anomalies(anomalies)}

    ## ⭐ Highlights

    #{render_highlights(highlights)}

    ---

    **Next Steps:**
    1. Review anomalies — adjust deep work schedule if needed
    2. Keep doing what's working (highlighted items)
    3. Task completion trending? Celebrate wins or identify blockers

    *This report auto-generates weekly from NATS outcomes events.*
    """
  end

  defp render_report_from_map(_), do: ""

  defp render_metrics(metrics) when is_map(metrics) do
    Enum.map_join(metrics, "\n", fn {name, data} ->
      "- **#{humanize(name)}**: #{format_value(data)}"
    end)
  end

  defp render_metrics(_), do: "No metrics available"

  defp render_anomalies([_ | _] = anomalies) do
    Enum.map_join(anomalies, "\n", fn anomaly -> "- #{anomaly}" end)
  end

  defp render_anomalies(_), do: "No anomalies detected — everything looks normal."

  defp render_highlights([_ | _] = highlights) do
    Enum.map_join(highlights, "\n", fn highlight -> "- #{highlight}" end)
  end

  defp render_highlights(_), do: "Continue your current pace."

  defp format_value(%{"current_value" => value, "trend_pct" => trend}) when is_number(value) do
    trend_str =
      if is_number(trend) and trend > 5 do
        " ↑ +#{Float.round(trend, 1)}%"
      else
        ""
      end

    "#{Float.round(value, 2)}#{trend_str}"
  end

  defp format_value(%{"current_value" => value}), do: "#{value}"
  defp format_value(_), do: "—"

  defp humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end

defmodule BotArmyGtd.Handlers.HealthHandler do
  @moduledoc """
  System health check handler - queries aggregator for service metrics.

  Responds to gtd.health requests with service performance data.
  Enables visibility into which services are performing well.
  """

  require Logger
  alias BotArmyGtd.Publisher

  @doc """
  Handle health check request.

  Expected payload:
    %{"type" => "full"} - include all service metrics
    %{"type" => "summary"} - only declining services

  Returns health status with service metrics.
  """
  def handle_health_check(message) do
    event_id = message["event_id"]
    payload = message["payload"] || %{}
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyGtd.Tenant.extract_context(message)

    case query_service_health(payload) do
      {:ok, health_data} ->
        Logger.info("Health check: #{health_data["summary"]}")

        publish_event(
          "gtd.health.report",
          health_data,
          event_id,
          message,
          tenant_id,
          user_id
        )

        {:ok, health_data}

      {:error, reason} ->
        Logger.warning("Health check failed: #{inspect(reason)}")

        publish_error(
          event_id,
          reason,
          "Health check unavailable",
          tenant_id,
          user_id
        )

        {:error, reason}
    end
  end

  defp query_service_health(payload) do
    type = payload["type"] || "summary"
    days = payload["days"] || 7

    try do
      # Query aggregator for all service metrics
      services = BotArmyAggregator.QueryService.list_services_health(days: days)

      case services do
        [] ->
          # No data yet from aggregator
          {:ok,
           %{
             "status" => "initializing",
             "summary" => "No service data yet. Aggregator starting up.",
             "services" => [],
             "period_days" => days,
             "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
           }}

        services ->
          # Format the health data
          formatted =
            case type do
              "full" ->
                format_full_health(services, days)

              "summary" ->
                format_summary_health(services, days)

              _ ->
                format_summary_health(services, days)
            end

          {:ok, formatted}
      end
    rescue
      e ->
        Logger.error("Health check exception: #{inspect(e)}")
        {:error, :aggregator_unavailable}
    end
  end

  defp format_full_health(services, days) do
    declining = Enum.filter(services, &(&1["trend"] == "declining"))
    improving = Enum.filter(services, &(&1["trend"] == "improving"))
    stable = Enum.filter(services, &(&1["trend"] == "stable"))

    status =
      if Enum.empty?(declining) do
        "healthy"
      else
        "degraded"
      end

    summary_text =
      if Enum.empty?(declining) do
        "All services healthy ✓"
      else
        decline_names =
          Enum.map(declining, fn s ->
            "#{s["service"]} (#{round(s["acceptance_rate"] * 100)}%)"
          end)

        "⚠️  #{Enum.join(decline_names, ", ")} trending down"
      end

    %{
      "status" => status,
      "summary" => summary_text,
      "period_days" => days,
      "services" => %{
        "improving" => improving,
        "stable" => stable,
        "declining" => declining
      },
      "counts" => %{
        "total" => length(services),
        "improving" => length(improving),
        "stable" => length(stable),
        "declining" => length(declining)
      },
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp format_summary_health(services, days) do
    declining = Enum.filter(services, &(&1["trend"] == "declining"))

    status =
      if Enum.empty?(declining) do
        "healthy"
      else
        "degraded"
      end

    summary_text =
      if Enum.empty?(declining) do
        "All services healthy ✓"
      else
        decline_names =
          Enum.map(declining, fn s ->
            "#{s["service"]} (#{round(s["acceptance_rate"] * 100)}%)"
          end)

        "⚠️  #{Enum.join(decline_names, ", ")} trending down"
      end

    # Only include declining services in summary
    service_list =
      Enum.map(declining, fn s ->
        %{
          "service" => s["service"],
          "acceptance_rate" => s["acceptance_rate"],
          "trend" => s["trend"],
          "outcomes_total" => s["outcomes_total"],
          "action" =>
            "Create improvement task: #{s["service"]} #{round(s["acceptance_rate"] * 100)}% → 75%"
        }
      end)

    %{
      "status" => status,
      "summary" => summary_text,
      "period_days" => days,
      "declining_services" => service_list,
      "action_count" => length(declining),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp publish_event(subject, payload, event_id, message, tenant_id, user_id) do
    event_data =
      BotArmyGtd.EventBuilder.build_event(
        subject,
        payload,
        tenant_id: tenant_id,
        user_id: user_id
      )

    case Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("[HealthHandler] Published health report")

      {:error, reason} ->
        Logger.warning("[HealthHandler] Failed to publish health report: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    error_payload = %{
      "error" => message,
      "reason" => inspect(reason),
      "event_id" => event_id
    }

    event_data =
      BotArmyGtd.EventBuilder.build_event(
        "gtd.health.error",
        error_payload,
        tenant_id: tenant_id,
        user_id: user_id
      )

    Publisher.publish(event_data)
  end
end

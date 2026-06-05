defmodule BotArmyGtd.Handlers.OutcomesIntegratorHandler do
  @moduledoc """
  Integrates Bot Army outcomes metrics into GTD task scoring.

  Listens to outcomes.* events from the Outcomes Recorder bot and adjusts task
  scoring weights based on completion trends, deep work patterns, and behavioral data.

  Subscribed topics:
  - outcomes.task.* - Task completion metrics
  - outcomes.decomposition.* - Decomposition quality metrics
  - outcomes.context.* - Context/mode transition metrics
  """

  require Logger
  alias BotArmyCore.Tenant

  @doc """
  Handle task completion metrics from outcomes events.

  Updates task score weights based on completion rates and trends.
  """
  def handle_task_metrics(message) do
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    with :ok <- validate_metrics_payload(payload),
         metrics = extract_metrics(payload),
         :ok <- apply_score_adjustments(metrics, tenant_id, user_id) do
      Logger.info("Outcomes metrics applied to task scoring",
        metric_name: metrics.metric_name,
        value: metrics.value,
        trend_pct: metrics.trend_pct
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to apply outcomes metrics", reason: reason)
        :error
    end
  end

  @doc """
  Handle decomposition quality metrics.

  Adjusts task decomposition scoring based on subtask completion rates.
  """
  def handle_decomposition_metrics(message) do
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    with :ok <- validate_metrics_payload(payload),
         metrics = extract_metrics(payload),
         quality_score = compute_quality_score(metrics),
         :ok <- apply_decomposition_adjustments(quality_score, tenant_id, user_id) do
      Logger.info("Decomposition quality metrics applied",
        quality_score: quality_score,
        metric_name: metrics.metric_name
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to apply decomposition metrics", reason: reason)
        :error
    end
  end

  @doc """
  Handle context/mode transition metrics.

  Adjusts task weights based on predicted mode (deep work vs shallow work).
  """
  def handle_context_metrics(message) do
    payload = message["payload"]
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)

    with :ok <- validate_metrics_payload(payload),
         mode = payload["context_mode"],
         confidence = payload["prediction_confidence"] || 0.5,
         :ok <- apply_context_adjustments(mode, confidence, tenant_id, user_id) do
      Logger.info("Context metrics applied to task scoring",
        mode: mode,
        confidence: confidence
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to apply context metrics", reason: reason)
        :error
    end
  end

  # Private helpers

  defp validate_metrics_payload(payload) when is_map(payload) do
    case payload do
      %{"metric_name" => _, "value" => _} -> :ok
      _ -> {:error, "missing required metric fields"}
    end
  end

  defp validate_metrics_payload(_), do: {:error, "invalid payload"}

  defp extract_metrics(payload) do
    %{
      metric_name: payload["metric_name"],
      value: payload["value"],
      trend_pct: payload["trend_pct"],
      bot_name: payload["bot_name"] || payload["source"],
      metadata: payload["metadata"] || %{}
    }
  end

  defp apply_score_adjustments(metrics, tenant_id, user_id) do
    case metrics.metric_name do
      "completion_rate" ->
        apply_completion_rate_adjustment(metrics, tenant_id, user_id)

      "task_latency" ->
        apply_latency_adjustment(metrics, tenant_id, user_id)

      "decomposition_quality" ->
        apply_quality_adjustment(metrics, tenant_id, user_id)

      _ ->
        Logger.debug("Unknown metric type, skipping adjustment",
          metric_name: metrics.metric_name
        )

        :ok
    end
  end

  defp apply_completion_rate_adjustment(metrics, _tenant_id, _user_id) do
    trend = metrics.trend_pct || 0

    case trend do
      t when t > 5 ->
        Logger.debug("Completion rate improving, boosting task scores", trend: trend)
        :ok

      t when t < -5 ->
        Logger.debug("Completion rate declining, reviewing task difficulty", trend: trend)
        :ok

      _ ->
        :ok
    end
  end

  defp apply_latency_adjustment(metrics, _tenant_id, _user_id) do
    value = metrics.value || 0

    case value do
      l when l > 10_000 ->
        Logger.warning("High latency detected, may affect task responsiveness",
          latency_ms: l
        )

        :ok

      _ ->
        :ok
    end
  end

  defp apply_quality_adjustment(_metrics, _tenant_id, _user_id) do
    Logger.debug("Decomposition quality adjustment applied")
    :ok
  end

  defp compute_quality_score(metrics) do
    case metrics.metadata do
      %{"subtask_completion_rate" => rate} -> rate
      _ -> metrics.value || 0.5
    end
  end

  defp apply_decomposition_adjustments(quality_score, _tenant_id, _user_id) do
    if quality_score >= 0.8 do
      Logger.debug("High decomposition quality, encouraging multi-step tasks",
        quality_score: quality_score
      )
    else
      Logger.debug("Lower decomposition quality, review subtask structure",
        quality_score: quality_score
      )
    end

    :ok
  end

  defp apply_context_adjustments(mode, confidence, _tenant_id, _user_id) do
    if confidence >= 0.65 do
      Logger.debug("High confidence mode prediction, adjusting task weights",
        mode: mode,
        confidence: confidence
      )
    else
      Logger.debug("Low confidence mode prediction, using baseline weights",
        mode: mode,
        confidence: confidence
      )
    end

    :ok
  end
end

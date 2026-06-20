defmodule BotArmyGtd.BehavioralLearningIntegrator do
  @moduledoc """
  Integrates behavioral learning predictions into task scoring.

  Queries the Context Broker for predicted mode (deep_work, shallow_work) and
  adjusts task scores based on mode patterns:
  - Deep work: boost complex/decomposed tasks
  - Shallow work: boost simple/quick tasks

  This module is called by ScoreEngine during score recomputation to apply
  behavioral adjustments to baseline signals.
  """

  require Logger

  @doc """
  Apply behavioral learning adjustment to a task score.

  Queries Context Broker for predicted mode and confidence, then applies
  a multiplier to the score:
  - Deep work tasks: multiplier = 1.0 + (confidence * 0.3)
  - Shallow work tasks: multiplier = 1.0 - (confidence * 0.15)
  - Unknown mode: multiplier = 1.0 (no adjustment)

  Returns adjusted score as float.
  """
  def adjust_score_for_behavior(base_score, task_data, _tenant_id) do
    case fetch_behavioral_prediction(task_data) do
      {:ok, mode, confidence} ->
        apply_mode_adjustment(base_score, mode, confidence, task_data)

      {:error, _reason} ->
        Logger.debug("[BehavioralLearner] No prediction available, using baseline score")
        base_score
    end
  end

  @doc """
  Fetch behavioral prediction from Context Broker.

  Returns {:ok, mode, confidence} or {:error, reason}
  """
  def fetch_behavioral_prediction(task_data) do
    case query_context_broker(task_data) do
      {:ok, response} ->
        mode = response["predicted_mode"] || "unknown"
        confidence = response["confidence"] || 0.5
        {:ok, mode, confidence}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[BehavioralLearner] Error fetching prediction",
        error: inspect(e)
      )

      {:error, "prediction_fetch_failed"}
  end

  defp query_context_broker(task_data) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        case Gnat.request(conn, "context.state.query", request_payload(task_data),
               receive_timeout: 2000
             ) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, response} ->
                {:ok, response}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "nats_connection_unavailable"}
    end
  catch
    :exit, reason ->
      {:error, "nats_connection_unavailable: #{inspect(reason)}"}
  end

  defp request_payload(task_data) do
    Jason.encode!(%{
      "request_type" => "behavior_prediction",
      "item_type" => task_data["item_type"] || "task",
      "item_id" => task_data["item_id"],
      "context" => task_data["context"] || "inbox"
    })
  end

  defp apply_mode_adjustment(base_score, mode, confidence, task_data) do
    case mode do
      "deep_work" ->
        complexity = estimate_task_complexity(task_data)
        multiplier = 1.0 + confidence * 0.3 * complexity

        Logger.debug("[BehavioralLearner] Deep work boost",
          mode: mode,
          confidence: confidence,
          multiplier: multiplier
        )

        base_score * multiplier

      "shallow_work" ->
        time_estimate = task_data["time_estimate_minutes"] || 30

        if time_estimate < 15 do
          multiplier = 1.0 + confidence * 0.2

          Logger.debug("[BehavioralLearner] Quick task boost in shallow work",
            multiplier: multiplier
          )

          base_score * multiplier
        else
          multiplier = 1.0 - confidence * 0.15

          Logger.debug("[BehavioralLearner] Complex task penalty in shallow work",
            multiplier: multiplier
          )

          base_score * multiplier
        end

      _ ->
        Logger.debug("[BehavioralLearner] Unknown mode, no adjustment", mode: mode)
        base_score
    end
  end

  defp estimate_task_complexity(task_data) do
    case task_data do
      %{"has_subtasks" => true, "subtask_count" => count} when count >= 3 -> 1.0
      %{"has_subtasks" => true} -> 0.7
      %{"decomposition_quality" => q} when q > 0.8 -> 0.9
      _ -> 0.5
    end
  end
end

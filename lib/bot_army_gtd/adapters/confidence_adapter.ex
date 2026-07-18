defmodule BotArmyGtd.Adapters.ConfidenceAdapter do
  @moduledoc """
  Integrates Dispatcher's confidence scoring with GTD task planning.

  Uses Dispatcher's RetryConfidenceOracle to make intelligent decisions about
  whether to retry failed tasks, replan them, or abort. Confidence thresholds:
  - >= 0.7: Proceed with retry (good chance of success)
  - 0.3-0.7: Allow medium-confidence retries
  - <= 0.3: Better to replan or abort

  ## Public API

  - `should_retry?(failed_task, dispatcher_confidence)` → boolean
  - `should_replan?(failed_task, retry_count, dispatcher_confidence)` → boolean
  - `get_dispatcher_confidence(bot_name)` → float (0.0-1.0)
  """

  require Logger
  alias BotArmyLibraryRuntime.NATS.Publisher

  @high_confidence 0.7
  @low_confidence 0.3
  @max_retries 3
  @nats_timeout_ms 3000

  @doc """
  Determine if a task should be retried based on dispatcher confidence.

  Returns true if:
  - Confidence is high (>= 0.7), indicating good chance of success on retry
  - We haven't exceeded max retries

  Returns false if:
  - Confidence is very low (< 0.3), better to replan
  - Max retries exceeded
  """
  def should_retry?(failed_task, dispatcher_confidence) when is_float(dispatcher_confidence) do
    retry_count = Map.get(failed_task, "retry_count", 0)

    cond do
      dispatcher_confidence >= @high_confidence and retry_count < @max_retries ->
        true

      dispatcher_confidence < @low_confidence ->
        false

      retry_count >= @max_retries ->
        false

      true ->
        # Confidence is medium (0.3-0.7), still room for retries
        retry_count < @max_retries
    end
  end

  def should_retry?(failed_task, _) do
    # Default to not retrying if confidence missing/invalid
    Map.get(failed_task, "retry_count", 0) < @max_retries
  end

  @doc """
  Determine if a task should be replanned based on retry count and confidence.

  Returns true if:
  - We've exhausted retries (retry_count > 3)
  - Confidence is very low (< 0.3) and we've already tried once
  - Multiple retries failed with no improvement

  Returns false if:
  - Still have retries left and confidence is acceptable
  """
  def should_replan?(_failed_task, retry_count, dispatcher_confidence)
      when is_float(dispatcher_confidence) and is_integer(retry_count) do
    cond do
      retry_count > @max_retries ->
        true

      dispatcher_confidence < @low_confidence and retry_count > 0 ->
        true

      true ->
        false
    end
  end

  def should_replan?(_failed_task, retry_count, _) when is_integer(retry_count) do
    retry_count > @max_retries
  end

  @doc """
  Query Dispatcher's RetryConfidenceOracle for confidence score on a bot.

  Makes a NATS request to dispatcher.retry.confidence with bot_name.
  Returns float between 0.0 and 1.0, or nil on error.

  Falls back to 0.5 (moderate confidence) if dispatcher unavailable.
  """
  def get_dispatcher_confidence(bot_name) when is_binary(bot_name) do
    case request_dispatcher_confidence(bot_name) do
      {:ok, confidence} when is_float(confidence) ->
        confidence

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch dispatcher confidence for #{bot_name}: #{inspect(reason)}, defaulting to 0.5"
        )

        0.5

      _ ->
        0.5
    end
  end

  @doc """
  Helper to increment retry counter on a task.
  """
  def increment_retry_count(task) when is_map(task) do
    retry_count = Map.get(task, "retry_count", 0)
    Map.put(task, "retry_count", retry_count + 1)
  end

  # Private helpers

  defp request_dispatcher_confidence(bot_name) do
    payload = %{
      "bot_name" => bot_name
    }

    case Publisher.request(
           "dispatcher.retry.confidence",
           payload,
           timeout_ms: @nats_timeout_ms
         ) do
      {:ok, response} ->
        confidence = Map.get(response, "confidence", 0.5)
        {:ok, confidence}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("Exception fetching dispatcher confidence: #{inspect(e)}")
      {:error, e}
  end
end

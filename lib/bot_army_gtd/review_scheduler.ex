defmodule BotArmyGtd.ReviewScheduler do
  @moduledoc """
  Periodic service that discovers decompositions due for review.

  Runs every N seconds (configurable), queries the decomposition store,
  and publishes events for decompositions with due_at <= now.

  Used by the TUI/frontend to populate a review queue and alert users
  about pending reviews.

  ## Configuration

  In config/config.exs:

  ```elixir
  config :bot_army_gtd, BotArmyGtd.ReviewScheduler,
    enabled: true,
    interval_seconds: 300  # Every 5 minutes
  ```
  """

  use GenServer
  require Logger

  @default_interval_seconds 300  # 5 minutes

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:bot_army_gtd, __MODULE__, [])[:enabled] || false
    interval = Application.get_env(:bot_army_gtd, __MODULE__, [])[:interval_seconds] || @default_interval_seconds

    Logger.info("ReviewScheduler: enabled=#{enabled}, interval=#{interval}s")

    if enabled do
      # Schedule first run immediately, then recurring
      Process.send_after(self(), :discover_due, 0)
      {:ok, %{interval: interval * 1000}}
    else
      {:ok, %{interval: interval * 1000}}
    end
  end

  @impl true
  def handle_info(:discover_due, state) do
    try do
      discover_due_decompositions()
    rescue
      e ->
        Logger.error("ReviewScheduler error: #{inspect(e)}")
    end

    # Schedule next run
    Process.send_after(self(), :discover_due, state.interval)
    {:noreply, state}
  end

  @doc """
  Get all decompositions due for review.

  Returns a list of maps with due decompositions, sorted by due_at.
  """
  def get_due do
    with {:ok, decompositions} <- get_store().list() do
      now = DateTime.utc_now()

      due =
        decompositions
        |> Enum.filter(fn d ->
          status = Map.get(d, "status")
          due_at_str = Map.get(d, "due_at")
          status == "completed" and due_at_str != nil
        end)
        |> Enum.filter(fn d ->
          due_at = parse_datetime(Map.get(d, "due_at"))
          due_at && DateTime.compare(due_at, now) in [:lt, :eq]
        end)
        |> Enum.sort_by(fn d ->
          parse_datetime(Map.get(d, "due_at"))
        end)

      {:ok, due}
    end
  end

  @doc """
  Get decompositions due for review in the next N days.
  """
  def get_upcoming(days \\ 7) do
    with {:ok, decompositions} <- get_store().list() do
      now = DateTime.utc_now()
      future = DateTime.add(now, days, :day)

      upcoming =
        decompositions
        |> Enum.filter(fn d ->
          status = Map.get(d, "status")
          due_at_str = Map.get(d, "due_at")
          status == "completed" and due_at_str != nil
        end)
        |> Enum.filter(fn d ->
          due_at = parse_datetime(Map.get(d, "due_at"))
          due_at && DateTime.compare(due_at, now) in [:gt, :eq] and
            DateTime.compare(due_at, future) in [:lt, :eq]
        end)
        |> Enum.sort_by(fn d ->
          parse_datetime(Map.get(d, "due_at"))
        end)

      {:ok, upcoming}
    end
  end

  # Private

  defp get_store do
    Application.get_env(:bot_army_gtd, :decomposition_store, BotArmyGtd.DecompositionStore)
  end

  defp discover_due_decompositions do
    case get_due() do
      {:ok, due_decompositions} ->
        if Enum.empty?(due_decompositions) do
          Logger.debug("ReviewScheduler: No decompositions due for review")
        else
          Enum.each(due_decompositions, fn decomposition ->
            log_due_decomposition(decomposition)
            publish_due_event(decomposition)
          end)

          Logger.info("ReviewScheduler: Found #{length(due_decompositions)} decompositions due for review")
        end

      {:error, reason} ->
        Logger.error("ReviewScheduler: Failed to list decompositions: #{inspect(reason)}")
    end
  end

  defp log_due_decomposition(decomposition) do
    id = Map.get(decomposition, "id")
    parent_task_id = Map.get(decomposition, "parent_task_id")
    due_at = Map.get(decomposition, "due_at")

    Logger.debug(
      "ReviewScheduler: Due decomposition: id=#{id}, parent_task_id=#{parent_task_id}, due_at=#{due_at}"
    )
  end

  defp publish_due_event(decomposition) do
    event_data = %{
      "event" => "gtd.decomposition.due_for_review",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "gtd.review_scheduler",
      "schema_version" => "1.0",
      "payload" => %{
        "decomposition_id" => Map.get(decomposition, "id"),
        "parent_task_id" => Map.get(decomposition, "parent_task_id"),
        "due_at" => Map.get(decomposition, "due_at"),
        "review_count" => Map.get(decomposition, "review_count")
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event_data) do
      {:ok, _subject} ->
        Logger.debug("ReviewScheduler: Published decomposition.due_for_review event")

      {:error, reason} ->
        Logger.error("ReviewScheduler: Failed to publish event: #{inspect(reason)}")
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil
end

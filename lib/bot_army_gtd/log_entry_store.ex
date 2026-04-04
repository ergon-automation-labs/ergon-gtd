defmodule BotArmyGtd.LogEntryStore do
  @moduledoc """
  In-memory log entry storage for the GTD bot.

  This GenServer maintains in-memory state of recent log entries while Ecto handles
  persistence to PostgreSQL. On init, it loads the last 7 days of log entries from
  the database to avoid full table scans.

  ## API

  - `create/1` - Create a new log entry
  - `list/1` - List log entries with optional filtering
  - `mark_file_written/1` - Mark a log entry as written to file
  """

  use GenServer
  require Logger
  import Ecto.Query

  @server __MODULE__
  @days_to_load 7

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new log entry from payload.

  Returns `{:ok, entry}` with the created entry, or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  List log entries for a tenant with optional filtering.

  Options:
  - `date` - Filter by date (Date.t())
  - `category` - Filter by category (string)
  - `limit` - Limit number of results (integer, default 100)

  Returns `{:ok, entries}`.
  """
  def list(tenant_id, opts \\ []) when is_binary(tenant_id) and is_list(opts) do
    GenServer.call(@server, {:list, tenant_id, opts})
  end

  @doc """
  Mark a log entry as written to file.

  Returns `{:ok, entry}` or `{:error, :not_found}`.
  """
  def mark_file_written(entry_id) when is_binary(entry_id) do
    GenServer.call(@server, {:mark_file_written, entry_id})
  end

  @doc """
  Mark a log entry as enriched with structured data.

  Returns `{:ok, entry}` or `{:error, :not_found}`.
  """
  def mark_enriched(entry_id, enrichment_data) when is_binary(entry_id) and is_map(enrichment_data) do
    GenServer.call(@server, {:mark_enriched, entry_id, enrichment_data})
  end

  @doc """
  Clear all log entries (for testing).

  Returns `:ok`.
  """
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("LogEntryStore started")

    state = try do
      # Load last 7 days of log entries
      cutoff_date = NaiveDateTime.utc_now() |> NaiveDateTime.add(-@days_to_load * 86400)

      entries = BotArmyGtd.Repo.all(
        from(e in BotArmyGtd.Schemas.LogEntry,
          where: e.inserted_at >= ^cutoff_date,
          order_by: [desc: e.inserted_at]
        )
      )

      Enum.reduce(entries, %{}, fn entry, acc ->
        Map.put(acc, entry.id |> to_string(), schema_to_map(entry))
      end)
    rescue
      _ ->
        Logger.warning("Could not load log entries from database (database unavailable). Starting with empty state.")
        %{}
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    entry_id = Ecto.UUID.generate()
    occurred_at = parse_occurred_at(Map.get(payload, "occurred_at"))

    changeset = BotArmyGtd.Schemas.LogEntry.changeset(
      %BotArmyGtd.Schemas.LogEntry{id: entry_id},
      %{
        "tenant_id" => payload["tenant_id"],
        "user_id" => Map.get(payload, "user_id"),
        "body" => payload["body"],
        "occurred_at" => occurred_at,
        "category" => Map.get(payload, "category", "personal"),
        "tags" => Map.get(payload, "tags", []),
        "task_id" => Map.get(payload, "task_id"),
        "project" => Map.get(payload, "project"),
        "source" => Map.get(payload, "source", "user"),
        "structured_data" => Map.get(payload, "structured_data")
      }
    )

    case BotArmyGtd.Repo.insert(changeset) do
      {:ok, db_entry} ->
        entry = schema_to_map(db_entry)
        new_state = Map.put(state, entry_id, entry)
        Logger.info("Created log entry in database: #{entry_id}")
        {:reply, {:ok, entry}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create log entry: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:list, tenant_id, opts}, _from, state) do
    entries = state
      |> Map.values()
      |> Enum.filter(&(&1["tenant_id"] == tenant_id))
      |> filter_by_date(Keyword.get(opts, :date))
      |> filter_by_category(Keyword.get(opts, :category))
      |> Enum.sort_by(&(&1["occurred_at"]), {:desc, NaiveDateTime})
      |> Enum.take(Keyword.get(opts, :limit, 100))

    {:reply, {:ok, entries}, state}
  end

  @impl true
  def handle_call({:mark_file_written, entry_id}, _from, state) do
    case Map.get(state, entry_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _entry ->
        entry_uuid = Ecto.UUID.cast!(entry_id)
        db_entry = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.LogEntry, entry_uuid)

        if db_entry do
          changeset = BotArmyGtd.Schemas.LogEntry.changeset(
            db_entry,
            %{"file_written" => true}
          )

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, updated_db_entry} ->
              updated_entry = schema_to_map(updated_db_entry)
              new_state = Map.put(state, entry_id, updated_entry)
              Logger.info("Marked log entry as file-written: #{entry_id}")
              {:reply, {:ok, updated_entry}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to mark log entry as written: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:mark_enriched, entry_id, enrichment_data}, _from, state) do
    case Map.get(state, entry_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _entry ->
        entry_uuid = Ecto.UUID.cast!(entry_id)
        db_entry = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.LogEntry, entry_uuid)

        if db_entry do
          changeset = BotArmyGtd.Schemas.LogEntry.changeset(
            db_entry,
            %{
              "enriched" => true,
              "enriched_at" => NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
              "structured_data" => enrichment_data
            }
          )

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, updated_db_entry} ->
              updated_entry = schema_to_map(updated_db_entry)
              new_state = Map.put(state, entry_id, updated_entry)
              Logger.info("Marked log entry as enriched: #{entry_id}")
              {:reply, {:ok, updated_entry}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to mark log entry as enriched: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all log entries from database and state")
    BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.LogEntry)
    {:reply, :ok, %{}}
  end

  # Helper functions

  defp schema_to_map(%BotArmyGtd.Schemas.LogEntry{} = entry) do
    %{
      "id" => Ecto.UUID.cast!(entry.id) |> to_string(),
      "tenant_id" => entry.tenant_id |> to_string(),
      "user_id" => if(entry.user_id, do: entry.user_id |> to_string(), else: nil),
      "body" => entry.body,
      "occurred_at" => entry.occurred_at |> NaiveDateTime.to_iso8601(),
      "category" => entry.category,
      "tags" => entry.tags,
      "task_id" => entry.task_id,
      "project" => entry.project,
      "source" => entry.source,
      "file_written" => entry.file_written,
      "enriched" => entry.enriched,
      "enriched_at" => if(entry.enriched_at, do: entry.enriched_at |> NaiveDateTime.to_iso8601(), else: nil),
      "structured_data" => entry.structured_data,
      "created_at" => entry.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => entry.updated_at |> NaiveDateTime.to_iso8601()
    }
  end

  defp parse_occurred_at(nil) do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp parse_occurred_at(iso_string) when is_binary(iso_string) do
    case NaiveDateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    end
  end

  defp parse_occurred_at(_) do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp filter_by_date(entries, nil), do: entries

  defp filter_by_date(entries, date) when is_struct(date, Date) do
    Enum.filter(entries, fn entry ->
      entry_date = entry["occurred_at"] |> NaiveDateTime.to_date()
      entry_date == date
    end)
  end

  defp filter_by_category(entries, nil), do: entries

  defp filter_by_category(entries, category) when is_binary(category) do
    Enum.filter(entries, &(&1["category"] == category))
  end
end

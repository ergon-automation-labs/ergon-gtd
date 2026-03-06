defmodule BotArmyGtd.InboxItemStore do
  @moduledoc """
  In-memory inbox item storage for the GTD bot.

  This GenServer maintains the in-memory state of all inbox items while Ecto handles
  persistence to PostgreSQL. On init, it loads all inbox items from the database.
  Every mutation (create, update) is persisted to the database before updating state.

  ## API

  - `create/1` - Create a new inbox item
  - `mark_processed/1` - Mark item as processed
  - `mark_discarded/1` - Mark item as discarded
  - `get/1` - Retrieve an inbox item by ID
  - `list_pending/0` - List all pending inbox items
  - `list_all/0` - List all inbox items
  """

  use GenServer
  require Logger

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new inbox item from payload.

  Returns `{:ok, item}` with the created item, or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Mark an inbox item as processed.

  Returns `{:ok, item}` or `{:error, :not_found}`.
  """
  def mark_processed(item_id) when is_binary(item_id) do
    GenServer.call(@server, {:mark_processed, item_id})
  end

  @doc """
  Mark an inbox item as discarded.

  Returns `{:ok, item}` or `{:error, :not_found}`.
  """
  def mark_discarded(item_id) when is_binary(item_id) do
    GenServer.call(@server, {:mark_discarded, item_id})
  end

  @doc """
  Retrieve an inbox item by ID.

  Returns `{:ok, item}` or `{:error, :not_found}`.
  """
  def get(item_id) when is_binary(item_id) do
    GenServer.call(@server, {:get, item_id})
  end

  @doc """
  List all pending inbox items.

  Returns `{:ok, items}`.
  """
  def list_pending do
    GenServer.call(@server, :list_pending)
  end

  @doc """
  List all inbox items including processed and discarded.

  Returns `{:ok, items}`.
  """
  def list_all do
    GenServer.call(@server, :list_all)
  end

  @doc """
  Clear all inbox items (for testing).

  Returns `:ok`.
  """
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("InboxItemStore started")
    # Load all inbox items from database
    # Gracefully handle database unavailability (e.g., in tests)
    state = try do
      items = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.InboxItem)
      Enum.reduce(items, %{}, fn item, acc ->
        Map.put(acc, item.id |> to_string(), schema_to_map(item))
      end)
    rescue
      _ ->
        Logger.warning("Could not load inbox items from database (database unavailable). Starting with empty state.")
        %{}
    end
    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    item_id = Ecto.UUID.generate()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    changeset = BotArmyGtd.Schemas.InboxItem.changeset(
      %BotArmyGtd.Schemas.InboxItem{id: item_id},
      %{
        "raw_text" => payload["raw_text"],
        "source" => Map.get(payload, "source", "user"),
        "source_metadata" => Map.get(payload, "source_metadata"),
        "received_at" => now,
        "status" => "pending"
      }
    )

    case BotArmyGtd.Repo.insert(changeset) do
      {:ok, db_item} ->
        item = schema_to_map(db_item)
        new_state = Map.put(state, item_id, item)
        Logger.info("Created inbox item in database: #{item_id}")
        {:reply, {:ok, item}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create inbox item: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:mark_processed, item_id}, _from, state) do
    case Map.get(state, item_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _item ->
        item_uuid = Ecto.UUID.cast!(item_id)
        db_item = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.InboxItem, item_uuid)

        if db_item do
          now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

          changeset = BotArmyGtd.Schemas.InboxItem.changeset(db_item, %{
            "status" => "clarified",
            "processed_at" => now
          })

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, updated_db_item} ->
              updated_item = schema_to_map(updated_db_item)
              new_state = Map.put(state, item_id, updated_item)
              Logger.info("Marked inbox item as processed: #{item_id}")
              {:reply, {:ok, updated_item}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to mark inbox item as processed: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:mark_discarded, item_id}, _from, state) do
    case Map.get(state, item_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _item ->
        item_uuid = Ecto.UUID.cast!(item_id)
        db_item = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.InboxItem, item_uuid)

        if db_item do
          changeset = BotArmyGtd.Schemas.InboxItem.changeset(db_item, %{
            "status" => "discarded"
          })

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, updated_db_item} ->
              updated_item = schema_to_map(updated_db_item)
              new_state = Map.put(state, item_id, updated_item)
              Logger.info("Marked inbox item as discarded: #{item_id}")
              {:reply, {:ok, updated_item}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to mark inbox item as discarded: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, item_id}, _from, state) do
    case Map.get(state, item_id) do
      nil -> {:reply, {:error, :not_found}, state}
      item -> {:reply, {:ok, item}, state}
    end
  end

  @impl true
  def handle_call(:list_pending, _from, state) do
    items =
      state
      |> Map.values()
      |> Enum.filter(fn item -> item["status"] == "pending" end)

    {:reply, {:ok, items}, state}
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    items = Map.values(state)
    {:reply, {:ok, items}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all inbox items")
    BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.InboxItem)
    {:reply, :ok, %{}}
  end

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%BotArmyGtd.Schemas.InboxItem{} = item) do
    %{
      "id" => Ecto.UUID.cast!(item.id) |> to_string(),
      "raw_text" => item.raw_text,
      "source" => item.source,
      "source_metadata" => item.source_metadata,
      "received_at" => item.received_at |> NaiveDateTime.to_iso8601(),
      "processed_at" =>
        if(item.processed_at, do: item.processed_at |> NaiveDateTime.to_iso8601(), else: nil),
      "status" => item.status,
      "created_at" => item.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => item.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end

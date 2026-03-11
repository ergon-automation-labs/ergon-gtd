defmodule BotArmyGtd.TaskStore do
  @moduledoc """
  In-memory task storage for the GTD bot.

  This is a mock implementation using a GenServer to maintain state.
  In production, this would use a persistent database like PostgreSQL.

  ## API

  - `create/1` - Create a new task
  - `update/2` - Update an existing task
  - `complete/1` - Mark a task as complete
  - `get/1` - Retrieve a task by ID
  - `list/0` - List all tasks
  """

  use GenServer
  require Logger

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new task from payload.

  Returns `{:ok, task}` with the created task, or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Update an existing task.

  Returns `{:ok, task}` with the updated task, or `{:error, reason}`.
  """
  def update(task_id, payload) when is_binary(task_id) and is_map(payload) do
    GenServer.call(@server, {:update, task_id, payload})
  end

  @doc """
  Mark a task as complete.

  Returns `{:ok, task}` with the completed task, or `{:error, reason}`.
  """
  def complete(task_id) when is_binary(task_id) do
    GenServer.call(@server, {:complete, task_id})
  end

  @doc """
  Retrieve a task by ID.

  Returns `{:ok, task}` or `{:error, :not_found}`.
  """
  def get(task_id) when is_binary(task_id) do
    GenServer.call(@server, {:get, task_id})
  end

  @doc """
  List all tasks.

  Returns `{:ok, tasks}`.
  """
  def list do
    GenServer.call(@server, :list)
  end

  @doc """
  Clear all tasks (for testing).

  Returns `:ok`.
  """
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("TaskStore started")
    # Load all tasks from database into GenServer state
    # Gracefully handle database unavailability (e.g., in tests)
    state = try do
      tasks = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.Task)
      Enum.reduce(tasks, %{}, fn task, acc ->
        Map.put(acc, task.id |> to_string(), schema_to_map(task))
      end)
    rescue
      _ ->
        Logger.warning("Could not load tasks from database (database unavailable). Starting with empty state.")
        %{}
    end
    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    task_id = Ecto.UUID.generate()

    # Parse due_date if present
    due_date = case Map.get(payload, "due_date") do
      nil -> nil
      date_str when is_binary(date_str) ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          {:error, _} -> nil
        end
      _ -> nil
    end

    # Create database record
    changeset = BotArmyGtd.Schemas.Task.changeset(
      %BotArmyGtd.Schemas.Task{id: task_id},
      %{
        "title" => payload["title"],
        "project_id" => payload["project_id"],
        "description" => Map.get(payload, "description"),
        "status" => Map.get(payload, "status", "active"),
        "priority" => Map.get(payload, "priority", "normal"),
        "context" => Map.get(payload, "context"),
        "source" => Map.get(payload, "source", "user"),
        "source_metadata" => Map.get(payload, "source_metadata"),
        "due_date" => due_date
      }
    )

    case BotArmyGtd.Repo.insert(changeset) do
      {:ok, db_task} ->
        task = schema_to_map(db_task)
        new_state = Map.put(state, task_id, task)
        Logger.info("Created task in database: #{task_id}")
        {:reply, {:ok, task}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create task: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, task_id, payload}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _task ->
        task_uuid = Ecto.UUID.cast!(task_id)
        db_task = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Task, task_uuid)

        if db_task do
          # Parse due_date if present
          due_date = case Map.get(payload, "due_date") do
            nil -> nil
            date_str when is_binary(date_str) ->
              case Date.from_iso8601(date_str) do
                {:ok, date} -> date
                {:error, _} -> nil
              end
            _ -> nil
          end

          changeset = BotArmyGtd.Schemas.Task.changeset(
            db_task,
            %{
              "title" => Map.get(payload, "title", db_task.title),
              "description" => Map.get(payload, "description", db_task.description),
              "status" => Map.get(payload, "status", db_task.status),
              "priority" => Map.get(payload, "priority", db_task.priority),
              "context" => Map.get(payload, "context", db_task.context),
              "source" => Map.get(payload, "source", db_task.source),
              "source_metadata" => Map.get(payload, "source_metadata", db_task.source_metadata),
              "due_date" => due_date || db_task.due_date
            }
          )

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, updated_db_task} ->
              updated_task = schema_to_map(updated_db_task)
              new_state = Map.put(state, task_id, updated_task)
              Logger.info("Updated task in database: #{task_id}")
              {:reply, {:ok, updated_task}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to update task: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:complete, task_id}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _task ->
        task_uuid = Ecto.UUID.cast!(task_id)
        db_task = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Task, task_uuid)

        if db_task do
          changeset = BotArmyGtd.Schemas.Task.changeset(
            db_task,
            %{
              "status" => "completed",
              "completed_at" => NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            }
          )

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, completed_db_task} ->
              completed_task = schema_to_map(completed_db_task)
              new_state = Map.put(state, task_id, completed_task)
              Logger.info("Completed task in database: #{task_id}")
              {:reply, {:ok, completed_task}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to complete task: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, task_id}, _from, state) do
    case Map.get(state, task_id) do
      nil -> {:reply, {:error, :not_found}, state}
      task -> {:reply, {:ok, task}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    tasks = state |> Map.values() |> Enum.reject(&(&1["status"] in ["deleted", "completed"]))
    {:reply, {:ok, tasks}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all tasks from database and state")
    # Clear database
    BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.Task)
    {:reply, :ok, %{}}
  end

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%BotArmyGtd.Schemas.Task{} = task) do
    %{
      "id" => Ecto.UUID.cast!(task.id) |> to_string(),
      "title" => task.title,
      "description" => task.description,
      "status" => task.status,
      "priority" => task.priority,
      "context" => task.context,
      "source" => task.source,
      "source_metadata" => task.source_metadata,
      "project_id" => task.project_id |> to_string(),
      "due_date" => if(task.due_date, do: task.due_date |> to_string(), else: nil),
      "completed_at" => if(task.completed_at, do: task.completed_at |> NaiveDateTime.to_iso8601(), else: nil),
      "created_at" => task.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => task.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end

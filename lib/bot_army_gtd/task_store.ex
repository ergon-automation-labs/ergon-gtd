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
  import Ecto.Query

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new task from payload, stamped with tenant_id.

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
  Update an existing task scoped to a tenant.

  Returns `{:ok, task}` with the updated task, or `{:error, reason}`.
  """
  def update(tenant_id, task_id, payload)
      when is_binary(tenant_id) and is_binary(task_id) and is_map(payload) do
    GenServer.call(@server, {:update_scoped, tenant_id, task_id, payload})
  end

  @doc """
  Mark a task as complete.

  Returns `{:ok, task}` with the completed task, or `{:error, reason}`.
  """
  def complete(task_id) when is_binary(task_id) do
    GenServer.call(@server, {:complete, task_id})
  end

  @doc """
  Mark a task as complete scoped to a tenant.

  Returns `{:ok, task}` with the completed task, or `{:error, reason}`.
  """
  def complete(tenant_id, task_id) when is_binary(tenant_id) and is_binary(task_id) do
    GenServer.call(@server, {:complete_scoped, tenant_id, task_id})
  end

  @doc """
  Retrieve a task by ID, scoped to a tenant.

  Returns `{:ok, task}` or `{:error, :not_found}`.
  """
  def get(tenant_id, task_id) when is_binary(tenant_id) and is_binary(task_id) do
    GenServer.call(@server, {:get, tenant_id, task_id})
  end

  @doc """
  List all tasks for a tenant.

  Optional filters:
  - "status" (string or list of strings)
  - "labels" (string or list of strings)

  Returns `{:ok, tasks}`.
  """
  def list(tenant_id, filters \\ %{}) when is_binary(tenant_id) and is_map(filters) do
    GenServer.call(@server, {:list, tenant_id, filters})
  end

  @doc """
  List all tasks for a tenant, prioritized by goal health.

  Tasks from at-risk goals (from Synapse) appear first, followed by other tasks.
  Gracefully handles NATS unavailability.

  Returns `{:ok, tasks}`.
  """
  def list_prioritized(tenant_id, filters \\ %{}) when is_binary(tenant_id) and is_map(filters) do
    {:ok, tasks} = list(tenant_id, filters)
    at_risk_goals = BotArmyGtd.ArmyContextConsumer.get_at_risk_goals()

    prioritized =
      Enum.sort_by(tasks, fn task ->
        # Tasks from at-risk goals sort first (false < true when sorted ascending)
        not Enum.any?(at_risk_goals, &(&1 == task["project_id"]))
      end)

    {:ok, prioritized}
  end

  @doc """
  Search tasks for a tenant by query string.

  Query matches against title and description (case-insensitive).
  Supports optional filters: status, context, labels, project_id, no_project.
  When `"no_project": true`, only tasks with no `project_id` are returned; `project_id`
  in filters is ignored for that request. Use query `"*"` to match all titles (see `SearchHandler`).
  Supports pagination: limit (default 50), offset (default 0).

  Returns `{:ok, {tasks, total_count}}`.
  """
  def search(tenant_id, query, filters \\ %{}, pagination \\ %{}) do
    GenServer.call(@server, {:search, tenant_id, query, filters, pagination})
  end

  @doc """
  List all tasks for a given plan.

  Returns `{:ok, tasks}` with tasks linked to the plan_id, or `{:error, reason}`.
  """
  def list_by_plan(tenant_id, plan_id)
      when is_binary(tenant_id) and is_binary(plan_id) do
    GenServer.call(@server, {:list_by_plan, tenant_id, plan_id})
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
    state =
      try do
        tasks = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.Task)

        Enum.reduce(tasks, %{}, fn task, acc ->
          Map.put(acc, task.id |> to_string(), schema_to_map(task))
        end)
      rescue
        _ ->
          Logger.warning(
            "Could not load tasks from database (database unavailable). Starting with empty state."
          )

          %{}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    task_id = Ecto.UUID.generate()

    # Parse due_date if present
    due_date =
      case Map.get(payload, "due_date") do
        nil ->
          nil

        date_str when is_binary(date_str) ->
          case Date.from_iso8601(date_str) do
            {:ok, date} -> date
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    # Create database record
    tenant_id = payload["tenant_id"]
    user_id = Map.get(payload, "user_id")

    changeset =
      BotArmyGtd.Schemas.Task.changeset(
        %BotArmyGtd.Schemas.Task{id: task_id},
        %{
          "tenant_id" => convert_to_uuid(tenant_id),
          "user_id" => if(user_id, do: convert_to_uuid(user_id), else: nil),
          "title" => payload["title"],
          "project_id" => payload["project_id"],
          "goal_id" => payload["goal_id"],
          "description" => Map.get(payload, "description"),
          "status" => Map.get(payload, "status", "active"),
          "priority" => Map.get(payload, "priority", "normal"),
          "context" => Map.get(payload, "context"),
          "source" => Map.get(payload, "source", "user"),
          "source_metadata" => Map.get(payload, "source_metadata"),
          "due_date" => due_date,
          "parent_task_id" => Map.get(payload, "parent_task_id"),
          "labels" => Map.get(payload, "labels", [])
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
        {:reply, {:error, changeset_error_reason(changeset)}, state}
    end
  end

  @impl true
  def handle_call({:update, task_id, payload}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _task ->
        task_uuid = Ecto.UUID.cast!(task_id)

        case execute_update_transaction(task_uuid, payload) do
          {:ok, updated_db_task} ->
            updated_task = schema_to_map(updated_db_task)
            new_state = Map.put(state, task_id, updated_task)
            Logger.info("Updated task in database: #{task_id}")
            {:reply, {:ok, updated_task}, new_state}

          {:error, :not_found} ->
            {:reply, {:error, :not_found}, state}

          {:error, changeset} ->
            Logger.error("Failed to update task: #{inspect(changeset.errors)}")
            {:reply, {:error, changeset_error_reason(changeset)}, state}
        end
    end
  end

  @impl true
  def handle_call({:update_scoped, tenant_id, task_id, payload}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        do_update_scoped_task(task, task_id, tenant_id, payload, state)
    end
  end

  @impl true
  def handle_call({:complete, task_id}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _task ->
        task_uuid = Ecto.UUID.cast!(task_id)
        completed_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        case BotArmyGtd.Repo.update_all(
               from(t in BotArmyGtd.Schemas.Task, where: t.id == ^task_uuid),
               set: [status: "completed", completed_at: completed_at]
             ) do
          {1, _} ->
            db_task = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Task, task_uuid)
            completed_task = schema_to_map(db_task)
            new_state = Map.put(state, task_id, completed_task)
            Logger.info("Completed task in database: #{task_id}")
            {:reply, {:ok, completed_task}, new_state}

          {0, _} ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:complete_scoped, tenant_id, task_id}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        do_complete_scoped_task(task, task_id, tenant_id, state)
    end
  end

  @impl true
  def handle_call({:get, tenant_id, task_id}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        # Verify tenant_id matches
        if task["tenant_id"] == tenant_id do
          {:reply, {:ok, task}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:list, tenant_id, filters}, _from, state) do
    # If state is empty, try to load from database (handles startup failure scenario)
    state_to_use =
      if map_size(state) == 0 do
        try do
          tasks = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.Task)
          Logger.info("TaskStore recovered #{length(tasks)} tasks from database")

          Enum.reduce(tasks, %{}, fn task, acc ->
            Map.put(acc, task.id |> to_string(), schema_to_map(task))
          end)
        rescue
          _ ->
            Logger.warning("TaskStore recovery from database failed, using empty state")
            state
        end
      else
        state
      end

    tasks =
      state_to_use
      |> Map.values()
      |> Enum.filter(&(&1["tenant_id"] == tenant_id))
      |> Enum.reject(&(&1["status"] in ["deleted", "completed"]))
      |> apply_list_filters(filters)
      |> sort_tasks(filters)

    {:reply, {:ok, tasks}, state_to_use}
  end

  @impl true
  def handle_call({:list_by_plan, tenant_id, plan_id}, _from, state) do
    # Load from database if state is empty
    state_to_use =
      if map_size(state) == 0 do
        try do
          tasks = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.Task)
          Logger.info("TaskStore recovered #{length(tasks)} tasks from database")

          Enum.reduce(tasks, %{}, fn task, acc ->
            Map.put(acc, task.id |> to_string(), schema_to_map(task))
          end)
        rescue
          _ ->
            Logger.warning("TaskStore recovery from database failed, using empty state")
            state
        end
      else
        state
      end

    tasks =
      state_to_use
      |> Map.values()
      |> Enum.filter(&(&1["tenant_id"] == tenant_id and Map.get(&1, "plan_id") == plan_id))
      |> Enum.sort_by(&Map.get(&1, "plan_order", 999))

    {:reply, {:ok, tasks}, state_to_use}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all tasks from database and state")
    # Clear database
    BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.Task)
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_call({:search, tenant_id, query, filters, pagination}, _from, state) do
    # Recover from database if state is empty
    state_to_use =
      if map_size(state) == 0 do
        try do
          tasks = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.Task)
          Logger.info("TaskStore recovered #{length(tasks)} tasks from database for search")

          Enum.reduce(tasks, %{}, fn task, acc ->
            Map.put(acc, task.id |> to_string(), schema_to_map(task))
          end)
        rescue
          _ ->
            Logger.warning("TaskStore recovery from database failed for search")
            state
        end
      else
        state
      end

    query_lower = String.downcase(query)
    limit = Map.get(pagination, "limit", 50)
    offset = Map.get(pagination, "offset", 0)

    # Get all tasks for tenant, then filter by query and optional filters
    all_tasks =
      state_to_use
      |> Map.values()
      |> Enum.filter(&(&1["tenant_id"] == tenant_id))

    # Filter by query across core text plus origin metadata for tracing.
    filtered_tasks =
      all_tasks
      |> Enum.filter(&task_matches_query?(&1, query_lower))

    # Apply optional filters
    no_project? = Map.get(filters, "no_project") == true

    filtered_tasks =
      filtered_tasks
      |> apply_filter(filters, no_project?)
      |> sort_tasks(pagination)

    # Apply pagination
    total_count = length(filtered_tasks)

    paginated_tasks =
      filtered_tasks
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, {:ok, {paginated_tasks, total_count}}, state_to_use}
  end

  defp apply_filter(tasks, filters, no_project?) when is_map(filters) do
    tasks
    |> apply_status_filter(Map.get(filters, "status"))
    |> apply_context_filter(Map.get(filters, "context"))
    |> apply_labels_filter(Map.get(filters, "labels"))
    |> apply_unassigned_project_filter(Map.get(filters, "no_project"))
    |> apply_project_filter(if(no_project?, do: nil, else: Map.get(filters, "project_id")))
    |> apply_goal_filter(Map.get(filters, "goal_id"))
  end

  defp apply_unassigned_project_filter(tasks, true) do
    Enum.filter(tasks, fn t ->
      case t["project_id"] do
        nil -> true
        "" -> true
        _ -> false
      end
    end)
  end

  defp apply_unassigned_project_filter(tasks, _), do: tasks

  defp apply_status_filter(tasks, nil), do: tasks

  defp apply_status_filter(tasks, status) when is_binary(status) do
    Enum.filter(tasks, &(&1["status"] == status))
  end

  defp apply_context_filter(tasks, nil), do: tasks

  defp apply_context_filter(tasks, context) when is_binary(context) do
    Enum.filter(tasks, &(&1["context"] == context))
  end

  defp apply_labels_filter(tasks, nil), do: tasks

  defp apply_labels_filter(tasks, labels) when is_list(labels) do
    Enum.filter(tasks, fn task ->
      task_labels = task["labels"] || []
      Enum.any?(labels, &Enum.member?(task_labels, &1))
    end)
  end

  defp apply_project_filter(tasks, nil), do: tasks

  defp apply_project_filter(tasks, project_id) when is_binary(project_id) do
    Enum.filter(tasks, &(&1["project_id"] == project_id))
  end

  defp apply_goal_filter(tasks, nil), do: tasks

  defp apply_goal_filter(tasks, goal_id) when is_binary(goal_id) do
    Enum.filter(tasks, &(&1["goal_id"] == goal_id))
  end

  defp task_matches_query?(_task, "*"), do: true

  defp task_matches_query?(task, query_lower) do
    metadata_text =
      case task["source_metadata"] do
        map when is_map(map) -> Jason.encode!(map) |> String.downcase()
        _ -> ""
      end

    searchable_fields = [
      task["title"],
      task["description"],
      task["source"],
      task["context"],
      task["id"],
      task["parent_task_id"],
      task["project_id"],
      task["goal_id"],
      metadata_text
    ]

    Enum.any?(searchable_fields, fn
      field when is_binary(field) and field != "" ->
        String.contains?(String.downcase(field), query_lower)

      _ ->
        false
    end)
  end

  defp apply_list_filters(tasks, filters) when is_map(filters) do
    tasks
    |> apply_list_status_filter(Map.get(filters, "status"))
    |> apply_list_labels_filter(Map.get(filters, "labels"))
  end

  defp apply_list_filters(tasks, _), do: tasks

  defp apply_list_status_filter(tasks, nil), do: tasks

  defp apply_list_status_filter(tasks, status) when is_binary(status) do
    Enum.filter(tasks, &(&1["status"] == status))
  end

  defp apply_list_status_filter(tasks, statuses) when is_list(statuses) do
    Enum.filter(tasks, &(&1["status"] in statuses))
  end

  defp apply_list_status_filter(tasks, _), do: tasks

  defp apply_list_labels_filter(tasks, nil), do: tasks

  defp apply_list_labels_filter(tasks, label) when is_binary(label) do
    Enum.filter(tasks, fn task ->
      label in (task["labels"] || [])
    end)
  end

  defp apply_list_labels_filter(tasks, labels) when is_list(labels) do
    Enum.filter(tasks, fn task ->
      task_labels = task["labels"] || []
      Enum.any?(labels, &Enum.member?(task_labels, &1))
    end)
  end

  defp apply_list_labels_filter(tasks, _), do: tasks

  defp sort_tasks(tasks, %{"sort" => sort_field, "order" => "desc"}) do
    Enum.sort_by(tasks, &sort_value(&1, sort_field), :desc)
  end

  defp sort_tasks(tasks, %{"sort" => sort_field}) do
    Enum.sort_by(tasks, &sort_value(&1, sort_field), :asc)
  end

  defp sort_tasks(tasks, _), do: tasks

  defp sort_value(task, "created_at"), do: task["created_at"] || ""
  defp sort_value(task, "updated_at"), do: task["updated_at"] || ""
  defp sort_value(task, "title"), do: task["title"] || ""
  defp sort_value(task, "priority"), do: task["priority"] || ""
  defp sort_value(task, field), do: Map.get(task, field, "")

  defp changeset_error_reason(%Ecto.Changeset{} = changeset) do
    {:validation_error, Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp changeset_error_reason(_), do: :database_error

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  # Convert string to UUID, handling both UUID strings and placeholder strings
  defp convert_to_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> generate_uuid_from_string(value)
    end
  end

  defp convert_to_uuid(value), do: value

  # Generate a consistent UUID from a string (e.g., "default" → deterministic UUID)
  defp generate_uuid_from_string(string) when is_binary(string) do
    hash = :crypto.hash(:sha256, string)
    <<uuid_int::128>> = binary_part(hash, 0, 16)
    <<uuid_int::128>> |> Ecto.UUID.cast() |> elem(1)
  end

  defp do_update_scoped_task(task, task_id, tenant_id, payload, state) do
    if task["tenant_id"] != tenant_id do
      {:reply, {:error, :not_found}, state}
    else
      task_uuid = Ecto.UUID.cast!(task_id)

      case execute_update_scoped_transaction(task_id, tenant_id, task_uuid, payload) do
        {:ok, updated_db_task} ->
          updated_task = schema_to_map(updated_db_task)
          new_state = Map.put(state, task_id, updated_task)
          Logger.info("Updated task in database (tenant scoped): #{task_id}")
          {:reply, {:ok, updated_task}, new_state}

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, changeset} ->
          Logger.error("Failed to update task (tenant scoped): #{inspect(changeset.errors)}")
          {:reply, {:error, changeset_error_reason(changeset)}, state}
      end
    end
  end

  defp do_complete_scoped_task(task, task_id, tenant_id, state) do
    if task["tenant_id"] != tenant_id do
      {:reply, {:error, :not_found}, state}
    else
      task_uuid = Ecto.UUID.cast!(task_id)

      case handle_complete_scoped(task_id, tenant_id, task_uuid, state) do
        {:ok, completed_task, new_state} ->
          {:reply, {:ok, completed_task}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%BotArmyGtd.Schemas.Task{} = task) do
    %{
      "id" => Ecto.UUID.cast!(task.id) |> to_string(),
      "tenant_id" => task.tenant_id |> to_string(),
      "user_id" => if(task.user_id, do: task.user_id |> to_string(), else: nil),
      "title" => task.title,
      "description" => task.description,
      "status" => task.status,
      "priority" => task.priority,
      "context" => task.context,
      "source" => task.source,
      "source_metadata" => task.source_metadata,
      "project_id" => if(task.project_id, do: to_string(task.project_id), else: nil),
      "goal_id" => if(task.goal_id, do: to_string(task.goal_id), else: nil),
      "parent_task_id" => if(task.parent_task_id, do: to_string(task.parent_task_id), else: nil),
      "labels" => task.labels,
      "due_date" => if(task.due_date, do: task.due_date |> to_string(), else: nil),
      "completed_at" =>
        if(task.completed_at, do: task.completed_at |> NaiveDateTime.to_iso8601(), else: nil),
      "result" => task.result,
      "created_at" => task.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => task.updated_at |> NaiveDateTime.to_iso8601()
    }
  end

  defp parse_due_date(nil), do: nil

  defp parse_due_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_due_date(_), do: nil

  defp handle_complete_scoped(task_id, tenant_id, task_uuid, state) do
    completed_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    query =
      from(t in BotArmyGtd.Schemas.Task,
        where: t.id == ^task_uuid and t.tenant_id == ^Ecto.UUID.cast!(tenant_id)
      )

    case BotArmyGtd.Repo.update_all(query, set: [status: "completed", completed_at: completed_at]) do
      {1, _} ->
        db_task = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Task, task_uuid)
        completed_task = schema_to_map(db_task)
        new_state = Map.put(state, task_id, completed_task)
        Logger.info("Completed task in database (tenant scoped): #{task_id}")
        {:ok, completed_task, new_state}

      {0, _} ->
        {:error, :not_found}
    end
  end

  defp build_and_update_task_changeset(db_task, payload) do
    due_date = parse_due_date(Map.get(payload, "due_date"))

    changeset =
      BotArmyGtd.Schemas.Task.changeset(
        db_task,
        %{
          "title" => Map.get(payload, "title", db_task.title),
          "description" => Map.get(payload, "description", db_task.description),
          "status" => Map.get(payload, "status", db_task.status),
          "priority" => Map.get(payload, "priority", db_task.priority),
          "context" => Map.get(payload, "context", db_task.context),
          "source" => Map.get(payload, "source", db_task.source),
          "source_metadata" => Map.get(payload, "source_metadata", db_task.source_metadata),
          "due_date" => due_date || db_task.due_date,
          "result" => Map.get(payload, "result", db_task.result),
          "project_id" => Map.get(payload, "project_id", db_task.project_id),
          "goal_id" => Map.get(payload, "goal_id", db_task.goal_id),
          "parent_task_id" => Map.get(payload, "parent_task_id", db_task.parent_task_id),
          "labels" => Map.get(payload, "labels", db_task.labels)
        }
      )

    case BotArmyGtd.Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> BotArmyGtd.Repo.rollback(changeset)
    end
  end

  defp execute_update_transaction(task_uuid, payload) do
    BotArmyGtd.Repo.transaction(fn ->
      db_task = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Task, task_uuid)

      if db_task do
        build_and_update_task_changeset(db_task, payload)
      else
        BotArmyGtd.Repo.rollback(:not_found)
      end
    end)
  end

  defp execute_update_scoped_transaction(task_id, tenant_id, task_uuid, payload) do
    BotArmyGtd.Repo.transaction(fn ->
      db_task = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Task, task_uuid)

      if db_task && db_task.tenant_id |> to_string() == tenant_id do
        build_and_update_task_changeset(db_task, payload)
      else
        BotArmyGtd.Repo.rollback(:not_found)
      end
    end)
  end
end

defmodule BotArmyGtd.DecompositionStore do
  @moduledoc """
  In-memory decomposition storage for the GTD bot.

  Stores task decomposition results from multi-step LLM chain inference.
  Persists to PostgreSQL with graceful degradation if database unavailable.

  ## API

  - `create/1` - Create a new decomposition
  - `get/1` - Retrieve a decomposition by ID
  - `get_by_parent_task/1` - Retrieve decomposition for a parent task
  - `update/2` - Update an existing decomposition
  - `list/0` - List all decompositions
  - `archive/1` - Archive a decomposition
  - `clear/0` - Clear all decompositions (testing)
  """

  @behaviour BotArmyGtd.DecompositionStoreBehaviour

  use GenServer
  require Logger

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new decomposition from payload.

  Returns `{:ok, decomposition}` with the created decomposition, or `{:error, reason}`.
  """
  @impl true
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Retrieve a decomposition by ID, scoped to a tenant.

  Returns `{:ok, decomposition}` or `{:error, :not_found}`.
  """
  @impl true
  def get(tenant_id, decomposition_id) when is_binary(tenant_id) and is_binary(decomposition_id) do
    GenServer.call(@server, {:get, tenant_id, decomposition_id})
  end

  @doc """
  Retrieve decomposition for a parent task, scoped to a tenant.

  Returns `{:ok, decomposition}` or `{:error, :not_found}`.
  """
  @impl true
  def get_by_parent_task(tenant_id, parent_task_id) when is_binary(tenant_id) and is_binary(parent_task_id) do
    GenServer.call(@server, {:get_by_parent_task, tenant_id, parent_task_id})
  end

  @doc """
  Update an existing decomposition.

  Returns `{:ok, decomposition}` with the updated decomposition, or `{:error, reason}`.
  """
  @impl true
  def update(decomposition_id, payload) when is_binary(decomposition_id) and is_map(payload) do
    GenServer.call(@server, {:update, decomposition_id, payload})
  end

  @doc """
  List all decompositions for a tenant.

  Returns `{:ok, decompositions}`.
  """
  @impl true
  def list(tenant_id) when is_binary(tenant_id) do
    GenServer.call(@server, {:list, tenant_id})
  end

  @doc """
  Archive a decomposition (set status to 'archived').

  Returns `{:ok, decomposition}` with the archived decomposition, or `{:error, reason}`.
  """
  @impl true
  def archive(decomposition_id) when is_binary(decomposition_id) do
    GenServer.call(@server, {:archive, decomposition_id})
  end

  @doc """
  Clear all decompositions (for testing).

  Returns `:ok`.
  """
  @impl true
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("DecompositionStore started")
    state = try do
      decompositions = BotArmyGtd.Repo.all(BotArmyGtd.Schemas.Decomposition)
      Enum.reduce(decompositions, %{}, fn decomposition, acc ->
        Map.put(acc, decomposition.id |> to_string(), schema_to_map(decomposition))
      end)
    rescue
      _ ->
        Logger.warning("Could not load decompositions from database (database unavailable). Starting with empty state.")
        %{}
    end
    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    decomposition_id = Ecto.UUID.generate()

    changeset = BotArmyGtd.Schemas.Decomposition.changeset(
      %BotArmyGtd.Schemas.Decomposition{id: decomposition_id},
      %{
        "tenant_id" => payload["tenant_id"],
        "user_id" => Map.get(payload, "user_id"),
        "parent_task_id" => payload["parent_task_id"],
        "status" => Map.get(payload, "status", "in_progress"),
        "step_outputs" => Map.get(payload, "step_outputs", []),
        "subtask_list" => Map.get(payload, "subtask_list"),
        "effort_estimates" => Map.get(payload, "effort_estimates"),
        "dependencies" => Map.get(payload, "dependencies"),
        "predicted_subtask_count" => Map.get(payload, "predicted_subtask_count"),
        "predicted_total_effort_hours" => Map.get(payload, "predicted_total_effort_hours"),
        "source_domain" => Map.get(payload, "source_domain"),
        "source_complexity_estimate" => Map.get(payload, "source_complexity_estimate")
      }
    )

    case BotArmyGtd.Repo.insert(changeset) do
      {:ok, db_decomposition} ->
        decomposition = schema_to_map(db_decomposition)
        new_state = Map.put(state, decomposition_id, decomposition)
        Logger.info("Created decomposition in database: #{decomposition_id}")
        {:reply, {:ok, decomposition}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create decomposition: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:get, tenant_id, decomposition_id}, _from, state) do
    case Map.get(state, decomposition_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decomposition ->
        # Verify tenant_id matches
        if decomposition["tenant_id"] == tenant_id do
          {:reply, {:ok, decomposition}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_by_parent_task, tenant_id, parent_task_id}, _from, state) do
    result = Enum.find(state, fn {_k, decomposition} ->
      decomposition["tenant_id"] == tenant_id and
      Map.get(decomposition, "parent_task_id") == parent_task_id
    end)

    case result do
      {_k, decomposition} -> {:reply, {:ok, decomposition}, state}
      nil -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update, decomposition_id, payload}, _from, state) do
    case Map.get(state, decomposition_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _decomposition ->
        decomposition_uuid = Ecto.UUID.cast!(decomposition_id)
        db_decomposition = BotArmyGtd.Repo.get(BotArmyGtd.Schemas.Decomposition, decomposition_uuid)

        if db_decomposition do
          changeset = BotArmyGtd.Schemas.Decomposition.changeset(
            db_decomposition,
            %{
              "status" => Map.get(payload, "status", db_decomposition.status),
              "step_outputs" => Map.get(payload, "step_outputs", db_decomposition.step_outputs),
              "subtask_list" => Map.get(payload, "subtask_list", db_decomposition.subtask_list),
              "effort_estimates" => Map.get(payload, "effort_estimates", db_decomposition.effort_estimates),
              "dependencies" => Map.get(payload, "dependencies", db_decomposition.dependencies),
              "stability" => Map.get(payload, "stability", db_decomposition.stability),
              "difficulty" => Map.get(payload, "difficulty", db_decomposition.difficulty),
              "due_at" => parse_due_at(Map.get(payload, "due_at", db_decomposition.due_at)),
              "review_count" => Map.get(payload, "review_count", db_decomposition.review_count),
              "last_grade" => Map.get(payload, "last_grade", db_decomposition.last_grade),
              "actual_subtask_count" => Map.get(payload, "actual_subtask_count", db_decomposition.actual_subtask_count),
              "user_rating" => Map.get(payload, "user_rating", db_decomposition.user_rating),
              "user_feedback" => Map.get(payload, "user_feedback", db_decomposition.user_feedback),
              "confidence_grade" => Map.get(payload, "confidence_grade", db_decomposition.confidence_grade)
            }
          )

          case BotArmyGtd.Repo.update(changeset) do
            {:ok, updated_db_decomposition} ->
              updated_decomposition = schema_to_map(updated_db_decomposition)
              new_state = Map.put(state, decomposition_id, updated_decomposition)
              Logger.info("Updated decomposition in database: #{decomposition_id}")
              {:reply, {:ok, updated_decomposition}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to update decomposition: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:list, tenant_id}, _from, state) do
    decompositions = state |> Map.values() |> Enum.filter(&(&1["tenant_id"] == tenant_id))
    {:reply, {:ok, decompositions}, state}
  end

  @impl true
  def handle_call({:archive, decomposition_id}, _from, state) do
    case Map.get(state, decomposition_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _decomposition ->
        update(decomposition_id, %{"status" => "reviewed"})
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all decompositions from database and state")
    BotArmyGtd.Repo.delete_all(BotArmyGtd.Schemas.Decomposition)
    {:reply, :ok, %{}}
  end

  # Helper to parse due_at which might be a DateTime or ISO8601 string
  defp parse_due_at(nil), do: nil
  defp parse_due_at(%DateTime{} = dt), do: dt

  defp parse_due_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_due_at(val), do: val

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%BotArmyGtd.Schemas.Decomposition{} = decomposition) do
    %{
      "id" => Ecto.UUID.cast!(decomposition.id) |> to_string(),
      "tenant_id" => decomposition.tenant_id |> to_string(),
      "user_id" => if(decomposition.user_id, do: decomposition.user_id |> to_string(), else: nil),
      "parent_task_id" => Ecto.UUID.cast!(decomposition.parent_task_id) |> to_string(),
      "status" => decomposition.status,
      "step_outputs" => decomposition.step_outputs,
      "subtask_list" => decomposition.subtask_list,
      "effort_estimates" => decomposition.effort_estimates,
      "dependencies" => decomposition.dependencies,
      "stability" => decomposition.stability,
      "difficulty" => decomposition.difficulty,
      "due_at" => if(decomposition.due_at, do: decomposition.due_at |> DateTime.to_iso8601(), else: nil),
      "review_count" => decomposition.review_count,
      "last_grade" => decomposition.last_grade,
      "predicted_subtask_count" => decomposition.predicted_subtask_count,
      "predicted_total_effort_hours" => decomposition.predicted_total_effort_hours,
      "actual_subtask_count" => decomposition.actual_subtask_count,
      "actual_total_effort_hours" => decomposition.actual_total_effort_hours,
      "user_rating" => decomposition.user_rating,
      "user_feedback" => decomposition.user_feedback,
      "confidence_grade" => decomposition.confidence_grade,
      "source_domain" => decomposition.source_domain,
      "source_complexity_estimate" => decomposition.source_complexity_estimate,
      "created_at" => decomposition.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => decomposition.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end

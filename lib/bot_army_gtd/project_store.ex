defmodule BotArmyGtd.ProjectStore do
  @moduledoc """
  In-memory project storage for the GTD bot.

  This is a mock implementation using a GenServer to maintain state.
  In production, this would use a persistent database like PostgreSQL.

  ## API

  - `create/1` - Create a new project
  - `update/2` - Update an existing project
  - `get/1` - Retrieve a project by ID
  - `list/0` - List all projects
  """

  use GenServer
  require Logger
  alias BotArmyGtd.Repo
  alias BotArmyGtd.Schemas.Project

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new project from payload.

  Returns `{:ok, project}` with the created project, or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Update an existing project.

  Returns `{:ok, project}` with the updated project, or `{:error, reason}`.
  """
  def update(project_id, payload) when is_binary(project_id) and is_map(payload) do
    GenServer.call(@server, {:update, project_id, payload})
  end

  @doc """
  Retrieve a project by ID, scoped to a tenant.

  Returns `{:ok, project}` or `{:error, :not_found}`.
  """
  def get(tenant_id, project_id) when is_binary(tenant_id) and is_binary(project_id) do
    GenServer.call(@server, {:get, tenant_id, project_id})
  end

  @doc """
  List all projects for a tenant.

  Returns `{:ok, projects}`.
  """
  def list(tenant_id) when is_binary(tenant_id) do
    GenServer.call(@server, {:list, tenant_id})
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("ProjectStore started")
    # Load all projects from database into GenServer state
    # Gracefully handle database unavailability (e.g., in tests)
    state =
      try do
        projects = Repo.all(Project)

        Enum.reduce(projects, %{}, fn project, acc ->
          Map.put(acc, project.id |> to_string(), schema_to_map(project))
        end)
      rescue
        _ ->
          Logger.warning(
            "Could not load projects from database (database unavailable). Starting with empty state."
          )

          %{}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    project_id = Ecto.UUID.generate()

    tenant_id = payload["tenant_id"]
    user_id = Map.get(payload, "user_id")

    changeset =
      Project.changeset(
        %Project{id: project_id},
        %{
          "tenant_id" => convert_to_uuid(tenant_id),
          "user_id" => if(user_id, do: convert_to_uuid(user_id), else: nil),
          "name" => payload["name"],
          "description" => Map.get(payload, "description"),
          "status" => Map.get(payload, "status", "active"),
          "area" => Map.get(payload, "area"),
          "labels" => Map.get(payload, "labels", [])
        }
      )

    case Repo.insert(changeset) do
      {:ok, db_project} ->
        project = schema_to_map(db_project)
        new_state = Map.put(state, project_id, project)
        Logger.info("Created project in database: #{project_id}")
        {:reply, {:ok, project}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create project: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, project_id, payload}, _from, state) do
    case Map.get(state, project_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _project ->
        project_uuid = Ecto.UUID.cast!(project_id)

        case execute_update_transaction(project_uuid, payload) do
          {:ok, updated_db_project} ->
            updated_project = schema_to_map(updated_db_project)
            new_state = Map.put(state, project_id, updated_project)
            Logger.info("Updated project in database: #{project_id}")
            {:reply, {:ok, updated_project}, new_state}

          {:error, :not_found} ->
            {:reply, {:error, :not_found}, state}

          {:error, changeset} ->
            Logger.error("Failed to update project: #{inspect(changeset.errors)}")
            {:reply, {:error, :database_error}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, tenant_id, project_id}, _from, state) do
    case Map.get(state, project_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      project ->
        # Verify tenant_id matches
        if project["tenant_id"] == tenant_id do
          {:reply, {:ok, project}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:list, tenant_id}, _from, state) do
    # If state is empty, try to load from database (handles startup failure scenario)
    state_to_use =
      if map_size(state) == 0 do
        try do
          projects = Repo.all(Project)
          Logger.info("ProjectStore recovered #{length(projects)} projects from database")

          Enum.reduce(projects, %{}, fn project, acc ->
            Map.put(acc, project.id |> to_string(), schema_to_map(project))
          end)
        rescue
          _ ->
            Logger.warning("ProjectStore recovery from database failed, using empty state")
            state
        end
      else
        state
      end

    projects = state_to_use |> Map.values() |> Enum.filter(&(&1["tenant_id"] == tenant_id))
    {:reply, {:ok, projects}, state_to_use}
  end

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%Project{} = project) do
    %{
      "id" => project.id |> to_string(),
      "tenant_id" => project.tenant_id |> to_string(),
      "user_id" => if(project.user_id, do: project.user_id |> to_string(), else: nil),
      "name" => project.name,
      "description" => project.description,
      "status" => project.status,
      "area" => project.area,
      "labels" => project.labels,
      "created_at" => project.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => project.updated_at |> NaiveDateTime.to_iso8601()
    }
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

  defp execute_update_transaction(project_uuid, payload) do
    BotArmyGtd.Repo.transaction(fn ->
      with db_project when db_project != nil <- Repo.get(Project, project_uuid),
           changeset <-
             Project.changeset(
               db_project,
               %{
                 "name" => Map.get(payload, "name", db_project.name),
                 "description" => Map.get(payload, "description", db_project.description),
                 "status" => Map.get(payload, "status", db_project.status),
                 "area" => Map.get(payload, "area", db_project.area),
                 "labels" => Map.get(payload, "labels", db_project.labels)
               }
             ),
           {:ok, updated} <- Repo.update(changeset) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end

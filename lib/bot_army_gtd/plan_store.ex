defmodule BotArmyGtd.PlanStore do
  @moduledoc """
  In-memory plan storage for the GTD bot.

  Stores high-level goals that have been decomposed into subtasks.
  Each plan tracks the overall status and can reference multiple related tasks.

  ## API

  - `create/1` - Create a new plan
  - `get/2` - Retrieve a plan by ID (tenant_id, plan_id)
  - `update/3` - Update an existing plan (tenant_id, plan_id, updates)
  - `list/2` - List plans with optional filters (tenant_id, filters)
  - `delete/2` - Delete a plan (tenant_id, plan_id)
  """

  use GenServer
  require Logger
  import Ecto.Query

  @behaviour BotArmyGtd.PlanStoreBehaviour

  alias BotArmyGtd.Repo
  alias BotArmyGtd.Schemas.Plan

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new plan from payload.

  Returns `{:ok, plan}` with the created plan, or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Get a plan by ID, scoped to a tenant.

  Returns `{:ok, plan}` or `{:error, :not_found}`.
  """
  def get(tenant_id, plan_id) when is_binary(tenant_id) and is_binary(plan_id) do
    GenServer.call(@server, {:get, tenant_id, plan_id})
  end

  @doc """
  Update an existing plan.

  Returns `{:ok, plan}` with the updated plan, or `{:error, reason}`.
  """
  def update(tenant_id, plan_id, payload)
      when is_binary(tenant_id) and is_binary(plan_id) and is_map(payload) do
    GenServer.call(@server, {:update, tenant_id, plan_id, payload})
  end

  @doc """
  List plans for a tenant with optional filters.

  Filters can include:
  - "status": "planning" | "executing" | "completed" | "failed" | "cancelled"

  Returns `{:ok, plans}`.
  """
  def list(tenant_id, filters \\ %{}) when is_binary(tenant_id) and is_map(filters) do
    GenServer.call(@server, {:list, tenant_id, filters})
  end

  @doc """
  Delete a plan (soft delete - sets status to cancelled).

  Returns `{:ok, plan}` or `{:error, reason}`.
  """
  def delete(tenant_id, plan_id) when is_binary(tenant_id) and is_binary(plan_id) do
    GenServer.call(@server, {:delete, tenant_id, plan_id})
  end

  @doc """
  Clear all plans (for testing).

  Returns `:ok`.
  """
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PlanStore started")

    state =
      try do
        plans = Repo.all(Plan)
        Logger.info("PlanStore loaded #{length(plans)} plans from database")

        Enum.reduce(plans, %{}, fn plan, acc ->
          Map.put(acc, plan.id |> to_string(), schema_to_map(plan))
        end)
      rescue
        _e ->
          Logger.warning("PlanStore initialization failed (expected in test)")
          %{}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    plan_id = Ecto.UUID.generate()

    changeset =
      Plan.changeset(
        %Plan{id: plan_id},
        %{
          "tenant_id" => convert_to_uuid(payload["tenant_id"]),
          "user_id" => convert_to_uuid(payload["user_id"]),
          "goal" => payload["goal"],
          "context" => Map.get(payload, "context", %{}),
          "constraints" => Map.get(payload, "constraints", %{}),
          "status" => Map.get(payload, "status", "planning"),
          "generated_by" => Map.get(payload, "generated_by", "llm_decomposer"),
          "decomposition_model" => Map.get(payload, "decomposition_model", "gpt4"),
          "result" => Map.get(payload, "result"),
          "notify_via_subject" => Map.get(payload, "notify_via_subject"),
          "metadata" => Map.get(payload, "metadata", %{})
        }
      )

    case Repo.insert(changeset) do
      {:ok, db_plan} ->
        plan = schema_to_map(db_plan)
        new_state = Map.put(state, plan_id, plan)
        Logger.info("Created plan in database: #{plan_id}")
        {:reply, {:ok, plan}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create plan: #{inspect(changeset.errors)}")
        {:reply, {:error, :invalid_payload}, state}
    end
  rescue
    e ->
      Logger.error("Plan creation failed: #{inspect(e)}")
      {:reply, {:error, :database_error}, state}
  end

  @impl true
  def handle_call({:get, tenant_id, plan_id}, _from, state) do
    case Map.get(state, plan_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plan ->
        # Verify tenant_id matches
        if plan["tenant_id"] == tenant_id do
          {:reply, {:ok, plan}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:update, tenant_id, plan_id, updates}, _from, state) do
    case Map.get(state, plan_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plan ->
        do_plan_update_scoped(plan, plan_id, tenant_id, updates, state)
    end
  rescue
    e ->
      Logger.error("Plan update failed: #{inspect(e)}")
      {:reply, {:error, :database_error}, state}
  end

  @impl true
  def handle_call({:list, tenant_id, filters}, _from, state) do
    # Load from database if state is empty
    state_to_use =
      if map_size(state) == 0 do
        try do
          plans = Repo.all(Plan)
          Logger.info("PlanStore recovered #{length(plans)} plans from database")

          Enum.reduce(plans, %{}, fn plan, acc ->
            Map.put(acc, plan.id |> to_string(), schema_to_map(plan))
          end)
        rescue
          _ ->
            Logger.warning("PlanStore recovery from database failed, using empty state")
            state
        end
      else
        state
      end

    plans =
      state_to_use
      |> Map.values()
      |> Enum.filter(&(&1["tenant_id"] == tenant_id))
      |> apply_list_filters(filters)

    {:reply, {:ok, plans}, state_to_use}
  end

  @impl true
  def handle_call({:delete, tenant_id, plan_id}, _from, state) do
    case Map.get(state, plan_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plan ->
        do_plan_delete_scoped(plan, plan_id, tenant_id, state)
    end
  rescue
    e ->
      Logger.error("Plan deletion failed: #{inspect(e)}")
      {:reply, {:error, :database_error}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.info("Clearing PlanStore")
    {:reply, :ok, %{}}
  end

  defp do_plan_update_scoped(plan, plan_id, tenant_id, updates, state) do
    if plan["tenant_id"] != tenant_id do
      {:reply, {:error, :not_found}, state}
    else
      plan_uuid = Ecto.UUID.cast!(plan_id)

      case handle_plan_update(plan_id, plan_uuid, updates) do
        {:ok, updated_plan, new_map} ->
          new_state = Map.merge(state, new_map)
          {:reply, {:ok, updated_plan}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp do_plan_delete_scoped(plan, plan_id, tenant_id, state) do
    if plan["tenant_id"] != tenant_id do
      {:reply, {:error, :not_found}, state}
    else
      plan_uuid = Ecto.UUID.cast!(plan_id)

      case handle_plan_delete(plan_id, plan_uuid) do
        {:ok, deleted_plan, new_map} ->
          new_state = Map.merge(state, new_map)
          {:reply, {:ok, deleted_plan}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  # Private helpers

  defp handle_plan_update(plan_id, plan_uuid, updates) do
    changeset =
      Repo.get(Plan, plan_uuid)
      |> Plan.changeset(updates)

    case Repo.update(changeset) do
      {:ok, db_plan} ->
        updated_plan = schema_to_map(db_plan)
        new_state = Map.put(%{}, plan_id, updated_plan)
        Logger.info("Updated plan in database: #{plan_id}")
        {:ok, updated_plan, new_state}

      {:error, _changeset} ->
        Logger.error("Failed to update plan #{plan_id}")
        {:error, :update_failed}
    end
  end

  defp handle_plan_delete(plan_id, plan_uuid) do
    changeset =
      Repo.get(Plan, plan_uuid)
      |> Plan.changeset(%{"status" => "cancelled"})

    case Repo.update(changeset) do
      {:ok, db_plan} ->
        deleted_plan = schema_to_map(db_plan)
        new_state = Map.put(%{}, plan_id, deleted_plan)
        Logger.info("Deleted plan in database: #{plan_id}")
        {:ok, deleted_plan, new_state}

      {:error, _changeset} ->
        Logger.error("Failed to delete plan #{plan_id}")
        {:error, :delete_failed}
    end
  end

  defp schema_to_map(schema) do
    %{
      "id" => schema.id |> to_string(),
      "tenant_id" => schema.tenant_id |> to_string(),
      "user_id" => if(schema.user_id, do: schema.user_id |> to_string(), else: nil),
      "goal" => schema.goal,
      "context" => schema.context || %{},
      "constraints" => schema.constraints || %{},
      "status" => schema.status,
      "generated_by" => schema.generated_by,
      "decomposition_model" => schema.decomposition_model,
      "result" => schema.result,
      "notify_via_subject" => schema.notify_via_subject,
      "metadata" => schema.metadata || %{},
      "created_at" =>
        schema.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601(),
      "started_at" =>
        if(schema.started_at, do: schema.started_at |> DateTime.to_iso8601(), else: nil),
      "completed_at" =>
        if(schema.completed_at, do: schema.completed_at |> DateTime.to_iso8601(), else: nil)
    }
  end

  defp convert_to_uuid(nil), do: nil
  defp convert_to_uuid(id) when is_binary(id), do: Ecto.UUID.cast!(id)
  defp convert_to_uuid(id), do: id

  defp apply_list_filters(plans, filters) do
    Enum.filter(plans, fn plan ->
      status_matches =
        case Map.get(filters, "status") do
          nil -> true
          status when is_binary(status) -> plan["status"] == status
          statuses when is_list(statuses) -> plan["status"] in statuses
          _ -> true
        end

      status_matches
    end)
  end
end

defmodule BotArmyGtd.TaskStoreOutageTest.LeaderStub do
  @moduledoc false
  # Stands in for BotArmyLibraryRuntime.LeaderElection when the test env has none:
  # the store only needs a process that answers :leader? with true.
  use GenServer

  @name :"Elixir.BotArmyLibraryRuntime.LeaderElection.gtd"

  def name, do: @name

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{is_leader: true}, name: @name)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:leader?, _from, state), do: {:reply, state.is_leader, state}
  def handle_call(_msg, _from, state), do: {:reply, {:ok, state}, state}
end

defmodule BotArmyGtd.TaskStoreOutageTest do
  use ExUnit.Case, async: false
  @moduletag :stores

  alias BotArmyGtd.TaskStore
  alias BotArmyGtd.TaskStoreOutageTest.LeaderStub
  alias BotArmyLibraryRuntime.Ecto.CircuitBreaker

  # Measured 2026-11-24 on the deployed 0.9.1: every gtd.task.create died as
  #
  #   ** (KeyError) key :errors not found in: {:circuit_open, 15482}
  #      lib/bot_army_gtd/task_store.ex:332: TaskStore.handle_call/3
  #
  # The database was unreachable (air's Postgres lived in a k8s cluster whose
  # datastore went malformed), so the breaker answered with an error tuple, the
  # `{:error, changeset}` clause bound it to the name `changeset`, and
  # `changeset.errors` raised. The consumer process died, so the caller got no
  # reply at all — a hung request and 310k lines of login failures, with nobody
  # told anything was wrong.
  #
  # handle_call/3 is a plain function of (call, from, state), so the store's
  # answer is testable without a database: open the breaker, call the same
  # entry point the consumer calls, and require an answer.
  setup do
    CircuitBreaker.reset()
    on_exit(fn -> CircuitBreaker.reset() end)

    leader = Process.whereis(:"Elixir.BotArmyLibraryRuntime.LeaderElection.gtd")
    on_exit(fn -> restore_leader(leader) end)
    become_leader(leader)
    :ok
  end

  test "a write with the database unavailable answers, it does not raise" do
    open_breaker()

    assert {:reply, {:error, {:database_unavailable, reason}}, %{}} =
             TaskStore.handle_call(
               {:create, %{"title" => "outage", "tenant_id" => tenant()}},
               nil,
               %{}
             )

    refute is_struct(reason, Ecto.Changeset),
           "a changeset means the database answered — this test needs it unreachable"
  end

  test "the reason names the breaker instead of pretending the payload was invalid" do
    open_breaker()

    assert {:reply, {:error, {:database_unavailable, reason}}, _state} =
             TaskStore.handle_call(
               {:create, %{"title" => "outage", "tenant_id" => tenant()}},
               nil,
               %{}
             )

    assert reason in [:database_error, :database_connection_failed, :circuit_breaker_unavailable] or
             match?({:circuit_open, _}, reason)
  end

  defp become_leader(nil), do: start_supervised!({LeaderStub, []})

  defp become_leader(pid) do
    :sys.replace_state(pid, fn state -> %{state | is_leader: true} end)
  end

  defp restore_leader(nil), do: :ok

  defp restore_leader(pid) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn state -> %{state | is_leader: false} end)
    end
  end

  defp open_breaker do
    for _ <- 1..5, do: GenServer.cast(CircuitBreaker, {:failure, :forced_by_test})
    # :get_state is a call, so it is processed after every cast above.
    assert %{state: :open} = CircuitBreaker.get_state()
  end

  defp tenant, do: "00000000-0000-0000-0000-000000000001"
end

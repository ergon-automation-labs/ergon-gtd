defmodule BotArmyGtd.TaskStoreLeaderGateTest do
  use ExUnit.Case, async: false
  @moduletag :stores

  alias BotArmyGtd.TaskStore

  # The scoped store paths answer "am I allowed to serve this?" before "does it
  # exist?". A standby (no leader lease) must say :not_leader -- never :not_found,
  # which is a factual claim about a task it cannot see. Before this gate a standby
  # answered {:error, :not_found} out of its own empty in-memory snapshot for a task
  # the leader had just written, and callers were told a landed write had failed
  # (and would retry it). See monorepo
  # docs/runbooks/KNOWN_ISSUE_STANDBY_BOT_LIES_ABOUT_WRITES.md.
  #
  # handle_call/3 is called directly: it is a plain function of (call, from, state),
  # so the refusal is testable without a GenServer, a database, or a leader election.
  # In the test environment LeaderMonitor.leader?/0 is false (no election runs), which
  # is exactly the standby case.
  setup do
    refute BotArmyGtd.LeaderMonitor.leader?(), "this test needs to run as a non-leader"
    :ok
  end

  test "a scoped update is refused as :not_leader, not as :not_found" do
    assert {:reply, {:error, :not_leader}, %{}} =
             TaskStore.handle_call(
               {:update_scoped, "tenant-1", "task-1", %{"title" => "x"}},
               nil,
               %{}
             )
  end

  test "a scoped read is refused as :not_leader, not as :not_found" do
    assert {:reply, {:error, :not_leader}, %{}} =
             TaskStore.handle_call({:get, "tenant-1", "task-1"}, nil, %{})
  end

  test "the refusal does not depend on the task being absent from the snapshot" do
    # A standby that happens to hold the task in memory must still refuse to serve it:
    # its snapshot is not the leader's database and may be arbitrarily stale.
    state = %{"task-1" => %{"id" => "task-1", "tenant_id" => "tenant-1", "title" => "stale"}}

    assert {:reply, {:error, :not_leader}, ^state} =
             TaskStore.handle_call({:get, "tenant-1", "task-1"}, nil, state)

    assert {:reply, {:error, :not_leader}, ^state} =
             TaskStore.handle_call(
               {:update_scoped, "tenant-1", "task-1", %{"title" => "x"}},
               nil,
               state
             )
  end
end

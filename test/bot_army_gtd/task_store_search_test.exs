defmodule BotArmyGtd.TaskStoreSearchTest do
  use ExUnit.Case
  @moduletag :stores

  setup do
    ensure_task_store_started!()
    original_state = :sys.get_state(BotArmyGtd.TaskStore)

    on_exit(fn ->
      case Process.whereis(BotArmyGtd.TaskStore) do
        nil ->
          :ok

        _pid ->
          :sys.replace_state(BotArmyGtd.TaskStore, fn _ -> original_state end)
      end
    end)

    :ok
  end

  defp ensure_task_store_started! do
    case Process.whereis(BotArmyGtd.TaskStore) do
      nil ->
        start_supervised!({BotArmyGtd.TaskStore, []})
        :ok

      _pid ->
        :ok
    end
  end

  test "search matches source_metadata content" do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    :sys.replace_state(BotArmyGtd.TaskStore, fn _ ->
      %{
        "task-1" => %{
          "id" => "task-1",
          "tenant_id" => tenant_id,
          "title" => "Follow up on parser output",
          "description" => nil,
          "status" => "active",
          "priority" => "normal",
          "context" => "inbox",
          "source" => "claude",
          "source_metadata" => %{
            "triggered_by_event_id" => "evt-123",
            "operation" => "claude.operation.success"
          },
          "project_id" => nil,
          "parent_task_id" => nil,
          "labels" => []
        }
      }
    end)

    {:ok, {tasks, total_count}} =
      BotArmyGtd.TaskStore.search(tenant_id, "claude.operation.success")

    assert total_count == 1
    assert length(tasks) == 1
    assert hd(tasks)["id"] == "task-1"
  end

  test "search matches parent_task_id content" do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    :sys.replace_state(BotArmyGtd.TaskStore, fn _ ->
      %{
        "task-2" => %{
          "id" => "task-2",
          "tenant_id" => tenant_id,
          "title" => "Subtask placeholder",
          "description" => nil,
          "status" => "inbox",
          "priority" => "normal",
          "context" => nil,
          "source" => "llm",
          "source_metadata" => %{},
          "project_id" => nil,
          "parent_task_id" => "parent-abc-123",
          "labels" => []
        }
      }
    end)

    {:ok, {tasks, total_count}} = BotArmyGtd.TaskStore.search(tenant_id, "parent-abc-123")

    assert total_count == 1
    assert length(tasks) == 1
    assert hd(tasks)["id"] == "task-2"
  end

  test "search matches source field content" do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    :sys.replace_state(BotArmyGtd.TaskStore, fn _ ->
      %{
        "task-3" => %{
          "id" => "task-3",
          "tenant_id" => tenant_id,
          "title" => "Investigate empty related info tasks",
          "description" => nil,
          "status" => "active",
          "priority" => "normal",
          "context" => nil,
          "source" => "claude",
          "source_metadata" => %{},
          "project_id" => nil,
          "parent_task_id" => nil,
          "labels" => []
        }
      }
    end)

    {:ok, {tasks, total_count}} = BotArmyGtd.TaskStore.search(tenant_id, "claude")

    assert total_count == 1
    assert length(tasks) == 1
    assert hd(tasks)["id"] == "task-3"
  end

  test "search and filter match goal_id content" do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    :sys.replace_state(BotArmyGtd.TaskStore, fn _ ->
      %{
        "task-4" => %{
          "id" => "task-4",
          "tenant_id" => tenant_id,
          "title" => "Link to goal",
          "description" => nil,
          "status" => "active",
          "priority" => "normal",
          "context" => nil,
          "source" => "claude",
          "source_metadata" => %{},
          "project_id" => nil,
          "goal_id" => "goal-xyz-1",
          "parent_task_id" => nil,
          "labels" => []
        }
      }
    end)

    {:ok, {tasks, total_count}} = BotArmyGtd.TaskStore.search(tenant_id, "goal-xyz-1")
    assert total_count == 1
    assert length(tasks) == 1
    assert hd(tasks)["id"] == "task-4"

    {:ok, filtered} = BotArmyGtd.TaskStore.list(tenant_id, %{"goal_id" => "goal-xyz-1"})
    assert length(filtered) == 1
    assert hd(filtered)["goal_id"] == "goal-xyz-1"
  end

  test "no_project filter with wildcard query returns only tasks without project_id" do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    :sys.replace_state(BotArmyGtd.TaskStore, fn _ ->
      %{
        "a" => %{
          "id" => "a",
          "tenant_id" => tenant_id,
          "title" => "In project alpha",
          "description" => nil,
          "status" => "active",
          "priority" => "normal",
          "context" => "next",
          "source" => "claude",
          "source_metadata" => %{},
          "project_id" => "proj-1",
          "parent_task_id" => nil,
          "labels" => []
        },
        "b" => %{
          "id" => "b",
          "tenant_id" => tenant_id,
          "title" => "Floating errand",
          "description" => nil,
          "status" => "active",
          "priority" => "normal",
          "context" => "inbox",
          "source" => "claude",
          "source_metadata" => %{},
          "project_id" => nil,
          "parent_task_id" => nil,
          "labels" => []
        }
      }
    end)

    {:ok, {tasks, total}} =
      BotArmyGtd.TaskStore.search(tenant_id, "*", %{"no_project" => true}, %{})

    assert total == 1
    assert hd(tasks)["id"] == "b"
  end
end

defmodule BotArmyGtd.Handlers.SubtaskHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  alias BotArmyGtd.Handlers.SubtaskHandler
  alias BotArmyLibraryCore.Tenant

  setup :verify_on_exit!

  setup do
    tenant_id = Tenant.default_tenant_id()
    user_id = "user-123"

    {:ok, tenant_id: tenant_id, user_id: user_id}
  end

  describe "handle_subtask_intent/1" do
    test "creates task from subtask intent with correct payload", %{
      tenant_id: tenant_id,
      user_id: user_id
    } do
      subtask_id = "subtask-" <> UUID.uuid4()
      decomposition_id = "decomp-" <> UUID.uuid4()
      task_id = "task-" <> UUID.uuid4()

      message = %{
        "event_id" => UUID.uuid4(),
        "tenant_id" => tenant_id,
        "user_id" => user_id,
        "payload" => %{
          "subtask_id" => subtask_id,
          "decomposition_id" => decomposition_id,
          "task_payload" => %{
            "title" => "Research company strategy",
            "description" => "Analyze competitor strategies",
            "priority" => "high"
          }
        }
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn task_data ->
        assert task_data["title"] == "Research company strategy"
        assert task_data["description"] == "Analyze competitor strategies"
        assert task_data["priority"] == "high"
        assert task_data["status"] == "inbox"
        assert task_data["tenant_id"] == tenant_id
        assert task_data["user_id"] == user_id
        {:ok, Map.put(task_data, "id", task_id)}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)

      SubtaskHandler.handle_subtask_intent(message)
    end

    test "uses default values for missing task fields", %{
      tenant_id: tenant_id,
      user_id: user_id
    } do
      subtask_id = "subtask-" <> UUID.uuid4()
      decomposition_id = "decomp-" <> UUID.uuid4()

      message = %{
        "event_id" => UUID.uuid4(),
        "tenant_id" => tenant_id,
        "user_id" => user_id,
        "payload" => %{
          "subtask_id" => subtask_id,
          "decomposition_id" => decomposition_id,
          "task_payload" => %{
            "description" => "Do something"
          }
        }
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn task_data ->
        assert task_data["title"] == "Subtask"
        assert task_data["description"] == "Do something"
        assert task_data["priority"] == "medium"
        assert task_data["status"] == "inbox"
        {:ok, Map.put(task_data, "id", UUID.uuid4())}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)
      SubtaskHandler.handle_subtask_intent(message)
    end

    test "handles task creation failure gracefully", %{
      tenant_id: tenant_id,
      user_id: user_id
    } do
      subtask_id = "subtask-" <> UUID.uuid4()
      decomposition_id = "decomp-" <> UUID.uuid4()

      message = %{
        "event_id" => UUID.uuid4(),
        "tenant_id" => tenant_id,
        "user_id" => user_id,
        "payload" => %{
          "subtask_id" => subtask_id,
          "decomposition_id" => decomposition_id,
          "task_payload" => %{
            "title" => "Task that will fail"
          }
        }
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn _task_data ->
        {:error, "Database connection failed"}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)

      SubtaskHandler.handle_subtask_intent(message)
    end

    test "extracts tenant and user context from message", %{
      user_id: user_id
    } do
      custom_tenant_id = UUID.uuid4()
      subtask_id = "subtask-" <> UUID.uuid4()
      decomposition_id = "decomp-" <> UUID.uuid4()

      message = %{
        "event_id" => UUID.uuid4(),
        "tenant_id" => custom_tenant_id,
        "user_id" => user_id,
        "payload" => %{
          "subtask_id" => subtask_id,
          "decomposition_id" => decomposition_id,
          "task_payload" => %{
            "title" => "Test task"
          }
        }
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn task_data ->
        assert task_data["tenant_id"] == custom_tenant_id
        assert task_data["user_id"] == user_id
        {:ok, Map.put(task_data, "id", UUID.uuid4())}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)
      SubtaskHandler.handle_subtask_intent(message)
    end
  end
end

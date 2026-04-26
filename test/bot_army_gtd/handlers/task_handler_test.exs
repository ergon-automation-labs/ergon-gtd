defmodule BotArmyGtd.Handlers.TaskHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  setup :verify_on_exit!

  describe "handle_create/1" do
    test "successfully creates a task" do
      expected_task = %{
        "id" => "test-task-id",
        "title" => "Learn Elixir",
        "project_id" => "project-1",
        "description" => "Master the fundamentals",
        "priority" => "normal",
        "status" => "active",
        "created_at" => "2024-01-01T00:00:00"
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, expected_task}
      end)

      message = valid_create_message()
      assert {:ok, ^expected_task} = BotArmyGtd.Handlers.TaskHandler.handle_create(message)
    end

    test "passes goal_id through create payload" do
      expect(BotArmyGtd.TaskStoreMock, :create, fn payload when is_map(payload) ->
        assert payload["goal_id"] == "goal-123"
        {:ok, %{"id" => "task-1", "title" => payload["title"], "goal_id" => payload["goal_id"]}}
      end)

      message =
        valid_create_message()
        |> put_in(["payload", "goal_id"], "goal-123")

      assert {:ok, %{"goal_id" => "goal-123"}} =
               BotArmyGtd.Handlers.TaskHandler.handle_create(message)
    end

    test "returns error for missing required field" do
      message =
        valid_create_message()
        |> put_in(["payload", "title"], nil)

      assert {:error, {:missing_field, "title"}} =
               BotArmyGtd.Handlers.TaskHandler.handle_create(message)
    end

    test "creates task and allows optional decomposition trigger flag" do
      expected_task = %{
        "id" => "decompose-task-id",
        "title" => "Break this down",
        "project_id" => "project-1",
        "priority" => "normal",
        "status" => "active"
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn payload when is_map(payload) ->
        assert payload["decompose"] == true
        {:ok, expected_task}
      end)

      message =
        valid_create_message()
        |> put_in(["payload", "decompose"], true)

      assert {:ok, ^expected_task} = BotArmyGtd.Handlers.TaskHandler.handle_create(message)
    end

    test "rejects suspicious nonode test payloads" do
      message =
        valid_create_message()
        |> Map.put("event_id", "parse-event-id")
        |> Map.put("source_node", "nonode@nohost")
        |> put_in(["payload", "task_id"], "task-1")

      assert {:error, :rejected_suspected_test_data} =
               BotArmyGtd.Handlers.TaskHandler.handle_create(message)
    end
  end

  describe "handle_update/1" do
    test "successfully updates a task" do
      task_id = "test-task-id"

      payload = %{
        "task_id" => task_id,
        "title" => "Updated Title",
        "priority" => "high"
      }

      expected_task = %{
        "id" => task_id,
        "title" => "Updated Title",
        "project_id" => "project-1",
        "priority" => "high",
        "status" => "active"
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok, %{"id" => task_id, "status" => "inbox", "source_metadata" => %{}}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["title"] == payload["title"]
        assert update_payload["priority"] == payload["priority"]
        {:ok, expected_task}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end

    test "passes goal_id through update payload" do
      task_id = "test-task-id"

      payload = %{
        "task_id" => task_id,
        "goal_id" => "goal-abc"
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok, %{"id" => task_id, "status" => "inbox", "source_metadata" => %{}}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["goal_id"] == "goal-abc"
        {:ok, %{"id" => task_id, "goal_id" => "goal-abc"}}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end

    test "returns error when updating non-existent task" do
      task_id = "non-existent-id"

      payload = %{
        "task_id" => task_id,
        "title" => "Updated Title"
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok, %{"id" => task_id, "status" => "inbox", "source_metadata" => %{}}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["title"] == payload["title"]
        {:error, :not_found}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      assert {:error, :not_found} = BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end

    test "refreshes active_until when updating active task" do
      task_id = "active-task-id"

      payload = %{
        "task_id" => task_id,
        "title" => "Still active"
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok, %{"id" => task_id, "status" => "active", "source_metadata" => %{}}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["source_metadata"]["active_until"]
        {:ok, %{"id" => task_id, "status" => "active"}}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end

    test "demotes expired active task to inbox with backlog note" do
      task_id = "expired-task-id"

      expired =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.to_iso8601()

      payload = %{
        "task_id" => task_id,
        "title" => "Old active task"
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok,
         %{
           "id" => task_id,
           "status" => "active",
           "description" => "existing desc",
           "source_metadata" => %{"active_until" => expired}
         }}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["status"] == "inbox"
        assert String.contains?(update_payload["description"], "PUSHED_TO_BACKLOG")
        assert update_payload["source_metadata"]["active_until"] == nil
        {:ok, %{"id" => task_id, "status" => "inbox"}}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end
  end

  describe "handle_complete/1" do
    test "successfully completes a task" do
      task_id = "test-task-id"

      expected_task = %{
        "id" => task_id,
        "title" => "Learn Elixir",
        "status" => "completed",
        "completed_at" => "2024-01-01T00:00:00"
      }

      expect(BotArmyGtd.TaskStoreMock, :complete, fn ^task_id ->
        {:ok, expected_task}
      end)

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.complete",
        "payload" => %{"task_id" => task_id}
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_complete(message)
    end

    test "returns error for non-existent task" do
      task_id = "non-existent-id"

      expect(BotArmyGtd.TaskStoreMock, :complete, fn ^task_id ->
        {:error, :not_found}
      end)

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.complete",
        "payload" => %{"task_id" => task_id}
      }

      assert {:error, :not_found} = BotArmyGtd.Handlers.TaskHandler.handle_complete(message)
    end
  end

  describe "handle_update/1 - Claude task operations" do
    test "successfully claims a task" do
      task_id = "test-task-id"

      payload = %{
        "task_id" => task_id,
        "status" => "claimed"
      }

      expected_task = %{
        "id" => task_id,
        "title" => "Test Task",
        "project_id" => "project-1",
        "priority" => "normal",
        "status" => "claimed"
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok, %{"id" => task_id, "status" => "inbox", "source_metadata" => %{}}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["status"] == payload["status"]
        {:ok, expected_task}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end

    test "successfully updates task with result" do
      task_id = "test-task-id"

      payload = %{
        "task_id" => task_id,
        "status" => "completed",
        "result" => %{
          "output" => "Task completed successfully",
          "success" => true,
          "metrics" => %{"duration_ms" => 123}
        }
      }

      expected_task = %{
        "id" => task_id,
        "title" => "Test Task",
        "status" => "completed",
        "result" => payload["result"]
      }

      expect(BotArmyGtd.TaskStoreMock, :get, fn _tenant_id, ^task_id ->
        {:ok, %{"id" => task_id, "status" => "inbox", "source_metadata" => %{}}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, update_payload ->
        assert update_payload["status"] == payload["status"]
        assert update_payload["result"] == payload["result"]
        {:ok, expected_task}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end
  end

  # Helper functions

  defp valid_create_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "gtd.task.create",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "tenant_id" => "00000000-0000-0000-0000-000000000001",
      "user_id" => nil,
      "payload" => %{
        "title" => "Learn Elixir",
        "project_id" => "project-1",
        "description" => "Master the fundamentals",
        "priority" => "normal"
      }
    }
  end
end

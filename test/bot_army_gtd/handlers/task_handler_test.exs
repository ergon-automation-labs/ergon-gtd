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
      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_create(message)
    end

    test "returns error for missing required field" do
      message =
        valid_create_message()
        |> put_in(["payload", "title"], nil)

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_create(message)
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

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, ^payload ->
        {:ok, expected_task}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => payload
      }

      BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)
    end

    test "returns error when updating non-existent task" do
      task_id = "non-existent-id"

      payload = %{
        "task_id" => task_id,
        "title" => "Updated Title"
      }

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, ^payload ->
        {:error, :not_found}
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

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_complete(message)
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

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, ^payload ->
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

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^task_id, ^payload ->
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

defmodule BotArmyGtd.Handlers.TaskHandlerTest do
  use ExUnit.Case

  setup do
    # Clear the task store before each test
    # The store may already be started by the application supervisor
    case BotArmyGtd.TaskStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear all tasks
    BotArmyGtd.TaskStore.clear()
    :ok
  end

  describe "handle_create/1" do
    test "successfully creates a task" do
      message = valid_create_message()

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_create(message)

      # Verify the task was stored
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      assert length(tasks) > 0

      task = List.first(tasks)
      assert task["title"] == "Learn Elixir"
      assert task["project_id"] == "project-1"
      assert task["status"] == "active"
    end

    test "returns error for missing required field" do
      message =
        valid_create_message()
        |> put_in(["payload", "title"], nil)

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_create(message)

      # Task should not be created
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      assert length(tasks) == 0
    end

    test "sets correct default values" do
      message = valid_create_message()

      BotArmyGtd.Handlers.TaskHandler.handle_create(message)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)

      assert task["priority"] == "normal"
      assert task["status"] == "active"
      assert is_binary(task["created_at"])
      assert is_binary(task["id"])
    end

    test "includes title and project_id in created task" do
      message = valid_create_message()

      BotArmyGtd.Handlers.TaskHandler.handle_create(message)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)

      assert task["title"] == "Learn Elixir"
      assert task["project_id"] == "project-1"
      assert task["description"] == "Master the fundamentals"
    end
  end

  describe "handle_update/1" do
    test "successfully updates an existing task" do
      # Create a task first
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      # Get the created task
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]

      # Update the task
      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => %{
          "task_id" => task_id,
          "title" => "Updated Title",
          "priority" => "high"
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)

      # Verify the task was updated
      {:ok, updated_task} = BotArmyGtd.TaskStore.get(task_id)
      assert updated_task["title"] == "Updated Title"
      assert updated_task["priority"] == "high"
    end

    test "returns error when updating non-existent task" do
      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => %{
          "task_id" => "non-existent-id",
          "title" => "Updated Title"
        }
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)

      # Verify no tasks were created
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      assert length(tasks) == 0
    end

    test "preserves unmodified fields during update" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]
      original_description = task["description"]

      # Update only the title
      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.update",
        "payload" => %{
          "task_id" => task_id,
          "title" => "New Title"
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_update(update_msg)

      # Verify description was preserved
      {:ok, updated_task} = BotArmyGtd.TaskStore.get(task_id)
      assert updated_task["title"] == "New Title"
      assert updated_task["description"] == original_description
    end
  end

  describe "handle_complete/1" do
    test "successfully marks a task as complete" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]

      # Complete the task
      complete_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.complete",
        "payload" => %{
          "task_id" => task_id
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_complete(complete_msg)

      # Verify the task was marked complete
      {:ok, completed_task} = BotArmyGtd.TaskStore.get(task_id)
      assert completed_task["status"] == "completed"
      assert is_binary(completed_task["completed_at"])
    end

    test "returns error when completing non-existent task" do
      complete_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.complete",
        "payload" => %{
          "task_id" => "non-existent-id"
        }
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_complete(complete_msg)

      # Verify no tasks were created
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      assert length(tasks) == 0
    end

    test "preserves other fields when completing" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]
      original_title = task["title"]

      # Complete the task
      complete_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.complete",
        "payload" => %{
          "task_id" => task_id
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_complete(complete_msg)

      # Verify title was preserved
      {:ok, completed_task} = BotArmyGtd.TaskStore.get(task_id)
      assert completed_task["title"] == original_title
      assert completed_task["status"] == "completed"
    end
  end

  describe "handle_defer/1" do
    test "successfully defers a task to a future date" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]

      # Defer the task
      defer_date = "2026-03-20"

      defer_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.command.defer",
        "payload" => %{
          "task_id" => task_id,
          "defer_until" => defer_date
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_defer(defer_msg)

      # Verify the task was deferred
      {:ok, deferred_task} = BotArmyGtd.TaskStore.get(task_id)
      assert deferred_task["due_date"] == defer_date
    end

    test "returns error when deferring non-existent task" do
      defer_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.command.defer",
        "payload" => %{
          "task_id" => "non-existent-id",
          "defer_until" => "2026-03-20"
        }
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_defer(defer_msg)

      # Verify no tasks were created
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      assert length(tasks) == 0
    end

    test "returns error when defer_until is missing" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]

      # Defer without defer_until
      defer_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.command.defer",
        "payload" => %{
          "task_id" => task_id
        }
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_defer(defer_msg)

      # Task should not be deferred
      {:ok, task} = BotArmyGtd.TaskStore.get(task_id)
      assert is_nil(task["due_date"])
    end
  end

  describe "handle_delete/1" do
    test "successfully marks a task as deleted" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]

      # Delete the task
      delete_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.command.delete",
        "payload" => %{
          "task_id" => task_id
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_delete(delete_msg)

      # Verify the task was marked as deleted
      {:ok, deleted_task} = BotArmyGtd.TaskStore.get(task_id)
      assert deleted_task["status"] == "deleted"
    end

    test "returns error when deleting non-existent task" do
      delete_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.command.delete",
        "payload" => %{
          "task_id" => "non-existent-id"
        }
      }

      assert :ok = BotArmyGtd.Handlers.TaskHandler.handle_delete(delete_msg)

      # Verify no tasks were created
      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      assert length(tasks) == 0
    end

    test "preserves other fields when deleting" do
      # Create a task
      create_msg = valid_create_message()
      BotArmyGtd.Handlers.TaskHandler.handle_create(create_msg)

      {:ok, tasks} = BotArmyGtd.TaskStore.list()
      task = List.first(tasks)
      task_id = task["id"]
      original_title = task["title"]

      # Delete the task
      delete_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.task.command.delete",
        "payload" => %{
          "task_id" => task_id
        }
      }

      BotArmyGtd.Handlers.TaskHandler.handle_delete(delete_msg)

      # Verify title was preserved
      {:ok, deleted_task} = BotArmyGtd.TaskStore.get(task_id)
      assert deleted_task["title"] == original_title
      assert deleted_task["status"] == "deleted"
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
      "payload" => %{
        "title" => "Learn Elixir",
        "project_id" => "project-1",
        "description" => "Master the fundamentals",
        "priority" => "normal"
      }
    }
  end
end

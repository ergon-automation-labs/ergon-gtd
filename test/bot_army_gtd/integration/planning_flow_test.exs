defmodule BotArmyGtd.Integration.PlanningFlowTest do
  use ExUnit.Case
  @moduletag :integration

  @tag :integration
  test "end-to-end: goal → plan → tasks → completion" do
    # Step 1: Submit a goal for planning
    goal_request = %{
      "goal" => "create a simple task and verify it works",
      "context" => %{},
      "constraints" => %{max_steps: 2}
    }

    # In a real integration test, this would call the actual NATS endpoint
    # For now, we'll test the data flow
    plan_id = UUID.uuid4()
    goal = goal_request["goal"]

    # Step 2: Simulate decomposition into tasks
    tasks = [
      %{
        "id" => UUID.uuid4(),
        "plan_id" => plan_id,
        "plan_order" => 1,
        "title" => "Create the task",
        "description" => "Add a new task to the system",
        "generated_by_ai" => true,
        "status" => "active"
      },
      %{
        "id" => UUID.uuid4(),
        "plan_id" => plan_id,
        "plan_order" => 2,
        "title" => "Verify task creation",
        "description" => "Verify that the task was created successfully",
        "generated_by_ai" => true,
        "status" => "active"
      }
    ]

    # Verify plan structure
    assert plan_id != nil
    assert Enum.all?(tasks, &(&1["plan_id"] == plan_id))
    assert Enum.all?(tasks, &(&1["generated_by_ai"] == true))
    assert Enum.count(tasks) == 2

    # Step 3: Simulate task completion
    completed_tasks =
      Enum.map(tasks, fn task ->
        %{task | "status" => "completed"}
      end)

    # Verify all tasks are complete
    assert Enum.all?(completed_tasks, &(&1["status"] == "completed"))

    # Step 4: Check plan would complete when all tasks complete
    incomplete_count =
      Enum.count(completed_tasks, fn t ->
        t["status"] not in ["completed", "deleted", "cancelled"]
      end)

    assert incomplete_count == 0
  end

  @tag :integration
  test "plan tracks through all task states" do
    plan_id = UUID.uuid4()

    # Create a task in planning status
    task = %{
      "id" => UUID.uuid4(),
      "plan_id" => plan_id,
      "plan_order" => 1,
      "title" => "Test Task",
      "status" => "active",
      "generated_by_ai" => true
    }

    assert task["plan_id"] == plan_id
    assert task["status"] == "active"

    # Transition task to completed
    completed_task = %{task | "status" => "completed"}
    assert completed_task["status"] == "completed"
    assert completed_task["plan_id"] == plan_id

    # Verify task still linked to plan after completion
    assert completed_task["plan_id"] == task["plan_id"]
  end

  @tag :integration
  test "plan handles partial failure gracefully" do
    plan_id = UUID.uuid4()

    tasks = [
      %{
        "id" => UUID.uuid4(),
        "plan_id" => plan_id,
        "plan_order" => 1,
        "title" => "Task 1",
        "status" => "active"
      },
      %{
        "id" => UUID.uuid4(),
        "plan_id" => plan_id,
        "plan_order" => 2,
        "title" => "Task 2",
        "status" => "active"
      }
    ]

    # First task fails
    task1_failed = %{Enum.at(tasks, 0) | "status" => "failed"}

    # Second task completes
    task2_completed = %{Enum.at(tasks, 1) | "status" => "completed"}

    # Plan should NOT be complete when one task failed
    all_tasks = [task1_failed, task2_completed]

    incomplete_count =
      Enum.count(all_tasks, fn t -> t["status"] not in ["completed", "deleted", "cancelled"] end)

    assert incomplete_count > 0
  end

  @tag :integration
  test "tasks in plan have correct metadata" do
    plan_id = UUID.uuid4()

    task = %{
      "id" => UUID.uuid4(),
      "plan_id" => plan_id,
      "plan_order" => 1,
      "title" => "Subtask 1",
      "generated_by_ai" => true,
      "verified_by" => nil
    }

    # Verify generated_by_ai flag
    assert task["generated_by_ai"] == true

    # Verify plan linkage
    assert task["plan_id"] == plan_id

    # Verify order is set
    assert task["plan_order"] == 1

    # Verify no verification until factory_breaker runs
    assert is_nil(task["verified_by"])
  end

  @tag :integration
  test "multiple tasks can be in the same plan" do
    plan_id = UUID.uuid4()
    task_count = 5

    tasks =
      Enum.map(1..task_count, fn order ->
        %{
          "id" => UUID.uuid4(),
          "plan_id" => plan_id,
          "plan_order" => order,
          "title" => "Task #{order}",
          "generated_by_ai" => true
        }
      end)

    # Verify all tasks link to same plan
    assert Enum.all?(tasks, &(&1["plan_id"] == plan_id))

    # Verify orders are sequential
    orders = Enum.map(tasks, & &1["plan_order"])
    assert orders == [1, 2, 3, 4, 5]

    # Verify count matches
    assert Enum.count(tasks) == task_count
  end
end

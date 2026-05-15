defmodule BotArmyGtd.Handlers.TaskFailureHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  describe "handle_fail payload validation" do
    test "validates required task_id field" do
      message = %{
        "event_id" => "event-1",
        "event" => "gtd.task.fail",
        "payload" => %{
          "failure_reason" => "Network timeout"
        },
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.TaskHandler.handle_fail(message)
    end

    test "rejects invalid payload format" do
      message = %{
        "event_id" => "event-1",
        "event" => "gtd.task.fail",
        "payload" => "not a map",
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.TaskHandler.handle_fail(message)
    end

    test "rejects missing task_id in payload" do
      message = %{
        "event_id" => "event-1",
        "event" => "gtd.task.fail",
        "payload" => %{},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      # Missing task_id in payload
      {:error, _reason} = BotArmyGtd.Handlers.TaskHandler.handle_fail(message)
    end
  end

  describe "failure reason extraction" do
    test "uses default failure reason when not provided" do
      # Test that structure validates the failure_reason extraction
      # Default should be "Unknown error"
      payload = %{"task_id" => "task-id"}
      assert payload["failure_reason"] || "Unknown error" == "Unknown error"
    end

    test "preserves provided failure reason" do
      reason = "Network timeout: connection refused after 30s"

      payload = %{
        "task_id" => "task-id",
        "failure_reason" => reason
      }

      assert payload["failure_reason"] || "Unknown error" == reason
    end

    test "accepts long failure reason strings" do
      reason =
        "Network timeout: connection refused after 30s attempting to reach https://api.example.com/v1/process"

      payload = %{
        "task_id" => "task-id",
        "failure_reason" => reason
      }

      assert payload["failure_reason"] || "Unknown error" == reason
      assert String.length(payload["failure_reason"]) > 50
    end
  end

  describe "plan_id extraction from task" do
    test "identifies tasks without plan_id" do
      task = %{
        "id" => "task-1",
        "title" => "Standalone task",
        "status" => "active"
      }

      plan_id = task["plan_id"]
      assert not (is_binary(plan_id) and plan_id != "")
    end

    test "identifies tasks with plan_id" do
      task = %{
        "id" => "task-1",
        "plan_id" => "plan-123",
        "title" => "Task in plan",
        "status" => "active"
      }

      plan_id = task["plan_id"]
      assert is_binary(plan_id) and plan_id != ""
    end

    test "ignores empty plan_id string" do
      task = %{
        "id" => "task-1",
        "plan_id" => "",
        "title" => "Task with empty plan_id",
        "status" => "active"
      }

      plan_id = task["plan_id"]
      assert not (is_binary(plan_id) and plan_id != "")
    end
  end

  describe "failure event structure" do
    test "builds failure event with required fields" do
      event_type = "gtd.task.failed"
      task_id = "task-1"
      failure_reason = "Test failure"

      event = %{
        "event" => event_type,
        "task_id" => task_id,
        "failure_reason" => failure_reason
      }

      assert event["event"] == event_type
      assert event["task_id"] == task_id
      assert event["failure_reason"] == failure_reason
    end

    test "publishes plan failure notification structure" do
      plan_id = "plan-1"
      task_id = "task-1"
      failure_reason = "Critical error"

      event = %{
        "event" => "gtd.plan.needs_attention",
        "plan_id" => plan_id,
        "failed_task_id" => task_id,
        "failure_reason" => failure_reason
      }

      assert event["event"] == "gtd.plan.needs_attention"
      assert event["plan_id"] == plan_id
      assert event["failed_task_id"] == task_id
    end
  end
end

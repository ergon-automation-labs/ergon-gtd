defmodule BotArmyGtd.Handlers.PlanHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  describe "handle_goal_plan payload validation" do
    test "rejects goal without goal field" do
      message = %{
        "event_id" => "event-1",
        "event" => "gtd.goal.plan",
        "payload" => %{
          "context" => %{},
          "constraints" => %{}
        },
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.PlanHandler.handle_goal_plan(message)
    end
  end

  describe "handle_goal_status payload validation" do
    test "validates required plan_id field" do
      message = %{
        "event_id" => "event-2",
        "event" => "gtd.goal.status",
        "payload" => %{},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.PlanHandler.handle_goal_status(message)
    end

    test "handles non-existent plan gracefully" do
      message = %{
        "event_id" => "event-2",
        "event" => "gtd.goal.status",
        "payload" => %{"plan_id" => "nonexistent-plan-id"},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.PlanHandler.handle_goal_status(message)
    end
  end

  describe "handle_goal_cancel payload validation" do
    test "validates required plan_id field" do
      message = %{
        "event_id" => "event-3",
        "event" => "gtd.goal.cancel",
        "payload" => %{"reason" => "User requested"},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.PlanHandler.handle_goal_cancel(message)
    end

    test "handles non-existent plan gracefully" do
      message = %{
        "event_id" => "event-3",
        "event" => "gtd.goal.cancel",
        "payload" => %{"plan_id" => "nonexistent-plan-id", "reason" => "User requested"},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:error, _reason} = BotArmyGtd.Handlers.PlanHandler.handle_goal_cancel(message)
    end
  end

  describe "handle_goal_list" do
    test "lists plans with filter parameter" do
      message = %{
        "event_id" => "event-4",
        "event" => "gtd.goal.list",
        "payload" => %{"filter" => "active"},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:ok, response} = BotArmyGtd.Handlers.PlanHandler.handle_goal_list(message)

      assert response["filter"] == "active"
      assert is_list(response["plans"])
    end

    test "lists all plans with 'all' filter" do
      message = %{
        "event_id" => "event-4",
        "event" => "gtd.goal.list",
        "payload" => %{"filter" => "all"},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:ok, response} = BotArmyGtd.Handlers.PlanHandler.handle_goal_list(message)

      assert response["filter"] == "all"
      assert is_list(response["plans"])
    end

    test "handles completed filter" do
      message = %{
        "event_id" => "event-4",
        "event" => "gtd.goal.list",
        "payload" => %{"filter" => "completed"},
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      {:ok, response} = BotArmyGtd.Handlers.PlanHandler.handle_goal_list(message)

      assert response["filter"] == "completed"
      assert is_list(response["plans"])
    end
  end
end

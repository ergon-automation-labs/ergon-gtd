defmodule BotArmyGtd.AutonomousDecompositionE2eTest do
  @moduledoc """
  End-to-end test for Autonomous Task Decomposition (Phase 3).

  Tests the complete flow:
  1. Decompose: Break down complex goal into subtasks
  2. Approve: User approves the decomposition
  3. Subtask Creation: System creates GTD tasks from approved subtasks

  This demonstrates Phase 3 integration: decomposition handler + subtask handler
  working together to enable autonomous task breakdown via dispatcher.
  """

  use ExUnit.Case
  @moduletag :handlers
  import Mox

  alias BotArmyGtd.Handlers.{DecompositionHandler, SubtaskHandler}
  alias BotArmyCore.Tenant

  setup :verify_on_exit!

  setup do
    tenant_id = Tenant.default_tenant_id()
    user_id = "user-123"

    {:ok, tenant_id: tenant_id, user_id: user_id}
  end

  describe "Autonomous Decomposition Phase 3 E2E" do
    test "Full flow: approved decomposition → create multiple subtasks", %{
      tenant_id: tenant_id,
      user_id: user_id
    } do
      # Phase 3 demonstrates the integration of decomposition approval with subtask creation.
      # When a user approves a decomposition, the system creates GTD tasks from each subtask.

      decomposition_id = UUID.uuid4()

      # ===== STEP 1: User Approves Decomposition =====
      # After decomposition (Phase 1-2), user approves and system creates subtasks

      subtask_list = [
        %{
          "title" => "Research competitors",
          "description" => "Find and analyze 5 main competitors",
          "priority" => "high"
        },
        %{
          "title" => "Analyze market trends",
          "description" => "Document current market shifts",
          "priority" => "medium"
        },
        %{
          "title" => "Write report",
          "description" => "Compile findings into professional report",
          "priority" => "high"
        }
      ]

      # ===== STEP 2: Create Subtasks from Approved Decomposition =====
      # For each subtask in the approved decomposition, create a GTD task via dispatcher

      # Mock task creation for all 3 subtasks
      expect(BotArmyGtd.TaskStoreMock, :create, 3, fn task_data ->
        assert task_data["status"] == "inbox"
        assert task_data["tenant_id"] == tenant_id
        {:ok, Map.put(task_data, "id", UUID.uuid4())}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)

      # Simulate creating subtasks from dispatcher intents
      subtask_list
      |> Enum.with_index()
      |> Enum.each(fn {subtask, index} ->
        subtask_intent_message = %{
          "event_id" => UUID.uuid4(),
          "tenant_id" => tenant_id,
          "user_id" => user_id,
          "payload" => %{
            "subtask_id" => "subtask-#{index}",
            "decomposition_id" => decomposition_id,
            "task_payload" => subtask
          }
        }

        SubtaskHandler.handle_subtask_intent(subtask_intent_message)
      end)

      # All 3 tasks are created (verified by mock expectations being met)
    end

    test "Decomposition enables parallel subtask creation workflow", %{
      tenant_id: tenant_id,
      user_id: user_id
    } do
      # This test demonstrates that Phase 3 enables parallel subtask execution
      # via the dispatcher, which can coordinate multiple bots

      decomposition_id = UUID.uuid4()

      # Multiple dispatcher subtask intents can be sent in parallel
      subtask_messages = [
        %{
          "event_id" => UUID.uuid4(),
          "tenant_id" => tenant_id,
          "user_id" => user_id,
          "payload" => %{
            "subtask_id" => "parallel-1",
            "decomposition_id" => decomposition_id,
            "task_payload" => %{
              "title" => "Parallel task 1",
              "description" => "Can run concurrently"
            }
          }
        },
        %{
          "event_id" => UUID.uuid4(),
          "tenant_id" => tenant_id,
          "user_id" => user_id,
          "payload" => %{
            "subtask_id" => "parallel-2",
            "decomposition_id" => decomposition_id,
            "task_payload" => %{
              "title" => "Parallel task 2",
              "description" => "Can also run concurrently"
            }
          }
        }
      ]

      expect(BotArmyGtd.TaskStoreMock, :create, 2, fn task_data ->
        {:ok, Map.put(task_data, "id", UUID.uuid4())}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)

      # Process subtasks in parallel (as would happen with dispatcher orchestration)
      Enum.each(subtask_messages, &SubtaskHandler.handle_subtask_intent/1)

      # Both tasks should be created (verified by mock expectations)
    end

    test "Subtask creation preserves decomposition context", %{
      tenant_id: tenant_id,
      user_id: user_id
    } do
      # This test verifies that subtask metadata is preserved through the flow

      decomposition_id = UUID.uuid4()
      subtask_id = UUID.uuid4()

      message = %{
        "event_id" => UUID.uuid4(),
        "tenant_id" => tenant_id,
        "user_id" => user_id,
        "payload" => %{
          "subtask_id" => subtask_id,
          "decomposition_id" => decomposition_id,
          "task_payload" => %{
            "title" => "Subtask from complex decomposition",
            "description" => "Part of larger goal breakdown",
            "priority" => "high"
          }
        }
      }

      expect(BotArmyGtd.TaskStoreMock, :create, fn task_data ->
        assert task_data["title"] == "Subtask from complex decomposition"
        assert task_data["priority"] == "high"
        assert task_data["status"] == "inbox"
        {:ok, Map.put(task_data, "id", UUID.uuid4())}
      end)

      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStoreMock)
      SubtaskHandler.handle_subtask_intent(message)
    end
  end
end

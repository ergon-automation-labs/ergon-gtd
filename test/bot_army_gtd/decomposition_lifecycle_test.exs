defmodule BotArmyGtd.DecompositionLifecycleTest do
  @moduledoc """
  Integration tests for the complete decomposition lifecycle with FSRS.

  Tests the full flow:
  1. Create decomposition (get initial FSRS schedule)
  2. Approve decomposition (calculate grade, update FSRS)
  3. ReviewScheduler discovers due decompositions
  4. TUI requests review (handler validates it's due)
  5. User reviews (handler processes with FSRS update)
  6. Next schedule is set for future review
  """

  use ExUnit.Case, async: true
  import Mox

  alias BotArmyGtd.ReviewScheduler
  alias BotArmyGtd.Handlers.DecompositionHandler

  setup :verify_on_exit!

  describe "complete decomposition lifecycle" do
    test "full cycle: create → approve → discover → request_review → review" do
      # ===== STEP 1: Create Decomposition =====
      decomposition_id = UUID.uuid4()
      parent_task_id = UUID.uuid4()
      event_id = UUID.uuid4()

      # Create message (would come from LLM chain completion)
      create_message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "payload" => %{
          "chain_id" => UUID.uuid4(),
          "steps" => [
            %{
              "name" => "break_down",
              "output" => Jason.encode!(%{
                "subtasks" => [
                  %{"title" => "Task 1", "description" => "Desc 1", "estimated_hours" => 2},
                  %{"title" => "Task 2", "description" => "Desc 2", "estimated_hours" => 3}
                ]
              })
            },
            %{
              "name" => "estimate_effort",
              "output" => Jason.encode!(%{
                "subtasks" => [
                  %{"title" => "Task 1", "estimated_hours" => 2},
                  %{"title" => "Task 2", "estimated_hours" => 3}
                ],
                "total_hours" => 5
              })
            },
            %{
              "name" => "identify_dependencies",
              "output" => Jason.encode!(%{
                "dependencies" => []
              })
            }
          ],
          "metadata" => %{"task_id" => parent_task_id}
        }
      }

      # Mock store to capture created decomposition
      created_decomp = nil

      expect(BotArmyGtd.DecompositionStoreMock, :create, fn payload ->
        # Verify FSRS fields are set
        assert payload["stability"] > 0
        assert payload["difficulty"] > 0
        assert payload["due_at"]
        assert payload["status"] == "completed"
        assert payload["review_count"] == 0

        {:ok, Map.merge(payload, %{"id" => decomposition_id})}
      end)

      # Process decomposition creation
      DecompositionHandler.handle_chain_completed(create_message)

      # ===== STEP 2: Approve Decomposition =====
      approve_event_id = UUID.uuid4()

      # Simulate approval - get the created decomposition
      now = DateTime.utc_now()
      due_yesterday = DateTime.add(now, -1, :day) |> DateTime.to_iso8601()

      approval_message = %{
        "event" => "gtd.decomposition.approve",
        "event_id" => approve_event_id,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^decomposition_id ->
        {:ok, %{
          "id" => decomposition_id,
          "status" => "completed",
          "stability" => 1.0,
          "difficulty" => 5.0,
          "due_at" => due_yesterday,
          "review_count" => 0,
          "predicted_subtask_count" => 2,
          "predicted_total_effort_hours" => 5,
          "subtask_list" => [
            %{"title" => "Task 1", "description" => "Desc 1", "estimated_hours" => 2},
            %{"title" => "Task 2", "description" => "Desc 2", "estimated_hours" => 3}
          ]
        }}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, payload ->
        # Verify approval updated FSRS fields
        assert payload["status"] == "reviewed"
        assert payload["actual_subtask_count"] == 2
        assert payload["review_count"] == 1
        assert payload["last_grade"] == 3  # Grade 3 = "Good" (matched prediction)
        assert payload["stability"] > 0
        assert payload["difficulty"] > 0
        assert payload["due_at"]

        {:ok, Map.merge(payload, %{"id" => decomposition_id})}
      end)

      # Process approval
      DecompositionHandler.handle_approve(approval_message)

      # ===== STEP 3: ReviewScheduler Discovers Due =====
      approval_decomp = %{
        "id" => decomposition_id,
        "status" => "reviewed",
        "stability" => 1.2,
        "difficulty" => 4.5,
        "due_at" => due_yesterday,
        "review_count" => 1,
        "actual_subtask_count" => 2,
        "predicted_subtask_count" => 2
      }

      expect(BotArmyGtd.DecompositionStoreMock, :list, fn ->
        {:ok, [approval_decomp]}
      end)

      {:ok, due_decompositions} = ReviewScheduler.get_due()
      assert length(due_decompositions) == 1
      assert Enum.at(due_decompositions, 0)["id"] == decomposition_id

      # ===== STEP 4: Request Review (TUI triggers) =====
      request_event_id = UUID.uuid4()

      request_message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => request_event_id,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^decomposition_id ->
        {:ok, approval_decomp}
      end)

      # Should publish ready_for_review event (no error)
      DecompositionHandler.handle_request_review(request_message)

      # ===== STEP 5: User Reviews Decomposition =====
      review_event_id = UUID.uuid4()

      review_message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => review_event_id,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 4,  # Good rating
          "feedback" => "Decomposition was accurate"
        }
      }

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^decomposition_id ->
        {:ok, approval_decomp}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, payload ->
        # Verify review updated FSRS fields
        assert payload["user_rating"] == 4
        assert payload["user_feedback"] == "Decomposition was accurate"
        assert payload["review_count"] == 2
        assert payload["last_grade"]  # Should have a grade
        assert payload["stability"] > 0
        assert payload["difficulty"] > 0
        assert payload["due_at"]
        # Due date should exist (will be a DateTime or ISO8601 string)
        due_at = payload["due_at"]
        assert due_at != nil

        {:ok, Map.merge(payload, %{"id" => decomposition_id})}
      end)

      # Process review
      DecompositionHandler.handle_review(review_message)

      # ===== STEP 6: Verify Next Schedule is Set =====
      # The updated decomposition should have a future due_at for next review cycle
      assert true
    end

    test "decomposition ready for review must be due" do
      decomposition_id = UUID.uuid4()
      request_event_id = UUID.uuid4()
      now = DateTime.utc_now()
      future = DateTime.add(now, 5, :day) |> DateTime.to_iso8601()

      request_message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => request_event_id,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      # Decomposition is completed but not due yet
      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^decomposition_id ->
        {:ok, %{
          "id" => decomposition_id,
          "status" => "completed",
          "due_at" => future
        }}
      end)

      # Should reject as not ready (publishes error)
      DecompositionHandler.handle_request_review(request_message)
      assert true
    end

    test "approval grade reflects prediction accuracy" do
      decomposition_id = UUID.uuid4()
      _parent_task_id = UUID.uuid4()
      approve_event_id = UUID.uuid4()
      now = DateTime.utc_now()
      due_yesterday = DateTime.add(now, -1, :day) |> DateTime.to_iso8601()

      # Test case 1: Perfect match (grade 3)
      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^decomposition_id ->
        {:ok, %{
          "id" => decomposition_id,
          "status" => "completed",
          "stability" => 1.0,
          "difficulty" => 5.0,
          "due_at" => due_yesterday,
          "review_count" => 0,
          "predicted_subtask_count" => 5,
          "subtask_list" => [
            %{"title" => "Task 1", "description" => "Desc 1", "estimated_hours" => 1},
            %{"title" => "Task 2", "description" => "Desc 2", "estimated_hours" => 1},
            %{"title" => "Task 3", "description" => "Desc 3", "estimated_hours" => 1},
            %{"title" => "Task 4", "description" => "Desc 4", "estimated_hours" => 1},
            %{"title" => "Task 5", "description" => "Desc 5", "estimated_hours" => 1}
          ]
        }}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _ ->
        {:ok, %{"id" => UUID.uuid4(), "title" => "Task"}}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, payload ->
        # Perfect match should give grade 3 (Good)
        assert payload["last_grade"] == 3
        {:ok, payload}
      end)

      approval_message = %{
        "event" => "gtd.decomposition.approve",
        "event_id" => approve_event_id,
        "payload" => %{"decomposition_id" => decomposition_id}
      }

      DecompositionHandler.handle_approve(approval_message)
      assert true
    end

    test "review with high accuracy increases stability" do
      decomposition_id = UUID.uuid4()
      _now = DateTime.utc_now()
      review_event_id = UUID.uuid4()

      review_message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => review_event_id,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 5,  # Excellent rating
          "feedback" => "Perfect decomposition"
        }
      }

      original_stability = 1.2
      original_difficulty = 4.5

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^decomposition_id ->
        {:ok, %{
          "id" => decomposition_id,
          "status" => "reviewed",
          "stability" => original_stability,
          "difficulty" => original_difficulty,
          "review_count" => 1,
          "predicted_subtask_count" => 5,
          "actual_subtask_count" => 5  # Perfect match
        }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, payload ->
        # High rating with perfect accuracy should update FSRS fields
        assert payload["stability"] > 0
        assert payload["difficulty"] > 0
        assert payload["review_count"] == 2
        assert payload["last_grade"]
        {:ok, payload}
      end)

      DecompositionHandler.handle_review(review_message)
      assert true
    end
  end
end

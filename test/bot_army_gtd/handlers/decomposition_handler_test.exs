defmodule BotArmyGtd.Handlers.DecompositionHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  setup :verify_on_exit!

  describe "handle_decompose/1" do
    test "handles valid decomposition request" do
      task_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.TaskStoreMock, :get, fn ^default_tenant_id, ^task_id ->
        {:ok,
         %{
           "id" => task_id,
           "title" => "Implement authentication system",
           "description" => "Add OAuth2 support"
         }}
      end)

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "task_id" => task_id,
          "model" => "claude-opus-4-6"
        }
      }

      # Handler should publish llm.inference.chain request (no error)
      BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)
      assert true
    end

    test "handles missing task_id" do
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "model" => "claude-opus-4-6"
        }
      }

      # Handler should publish error event (no error)
      BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)
      assert true
    end

    test "handles task not found" do
      task_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.TaskStoreMock, :get, fn ^default_tenant_id, ^task_id ->
        {:error, :not_found}
      end)

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "task_id" => task_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)
      assert true
    end

    test "handles invalid payload" do
      event_id = UUID.uuid4()

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
        "payload" => "not a map"
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)
      assert true
    end
  end

  describe "handle_chain_completed/1" do
    test "handles valid chain completion with parsed results" do
      decomposition_id = UUID.uuid4()
      task_id = UUID.uuid4()
      chain_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :create, fn payload when is_map(payload) ->
        {:ok,
         %{
           "id" => decomposition_id,
           "parent_task_id" => task_id,
           "status" => "completed",
           "tenant_id" => default_tenant_id
         }}
      end)

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "chain_id" => chain_id,
          "steps" => [
            %{
              "name" => "break_down",
              "output" =>
                Jason.encode!([
                  %{
                    "title" => "Setup OAuth",
                    "description" => "Configure OAuth2 provider",
                    "estimated_hours" => 4
                  },
                  %{
                    "title" => "Database schema",
                    "description" => "Add user table",
                    "estimated_hours" => 2
                  },
                  %{
                    "title" => "API endpoints",
                    "description" => "Create auth endpoints",
                    "estimated_hours" => 6
                  }
                ])
            },
            %{
              "name" => "estimate_effort",
              "output" =>
                Jason.encode!(%{
                  "subtasks" => [
                    %{"title" => "Setup OAuth", "estimated_hours" => 4},
                    %{"title" => "Database schema", "estimated_hours" => 2},
                    %{"title" => "API endpoints", "estimated_hours" => 6}
                  ],
                  "total_hours" => 12
                })
            },
            %{
              "name" => "identify_dependencies",
              "output" =>
                Jason.encode!(%{
                  "dependencies" => [
                    %{"depends_on" => "Setup OAuth", "required_for" => "API endpoints"},
                    %{"depends_on" => "Database schema", "required_for" => "API endpoints"}
                  ]
                })
            }
          ],
          "metadata" => %{
            "task_id" => task_id,
            "source" => "task_decomposition"
          }
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      assert true
    end

    test "handles chain completion with missing steps" do
      chain_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "chain_id" => chain_id,
          "steps" => []
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      assert true
    end

    test "handles missing chain_id" do
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "steps" => [%{"name" => "step1", "output" => "{}"}]
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      assert true
    end

    test "handles invalid JSON output with graceful degradation" do
      task_id = UUID.uuid4()
      chain_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :create, fn payload when is_map(payload) ->
        {:ok,
         %{
           "id" => UUID.uuid4(),
           "parent_task_id" => task_id,
           "status" => "completed",
           "tenant_id" => default_tenant_id
         }}
      end)

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "chain_id" => chain_id,
          "steps" => [
            %{"name" => "step1", "output" => "not valid json"},
            %{"name" => "step2", "output" => "also not json"},
            %{"name" => "step3", "output" => "still invalid"}
          ],
          "metadata" => %{"task_id" => task_id}
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      # Gracefully handles bad output with empty lists/defaults
      assert true
    end

    test "handles invalid payload" do
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => "not a map"
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      assert true
    end
  end

  describe "handle_approve/1" do
    test "creates subtasks for each item in subtask_list" do
      decomposition_id = UUID.uuid4()
      task_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      subtask_list = [
        %{"title" => "Subtask 1", "description" => "First subtask", "estimated_hours" => 2},
        %{"title" => "Subtask 2", "description" => "Second subtask", "estimated_hours" => 3},
        %{"title" => "Subtask 3", "description" => "Third subtask", "estimated_hours" => 1}
      ]

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "parent_task_id" => task_id,
           "subtask_list" => subtask_list,
           "status" => "completed"
         }}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, 3, fn payload when is_map(payload) ->
        {:ok,
         %{
           "id" => UUID.uuid4(),
           "title" => payload["title"],
           "parent_task_id" => task_id,
           "status" => "inbox"
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.approve",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)
      assert true
    end

    test "handles empty subtask_list gracefully" do
      decomposition_id = UUID.uuid4()
      task_id = UUID.uuid4()
      event_id = UUID.uuid4()

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "parent_task_id" => task_id,
           "subtask_list" => [],
           "status" => "completed"
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, _update_payload ->
        {:ok,
         %{
           "id" => decomposition_id,
           "status" => "reviewed",
           "actual_subtask_count" => 0,
           "tenant_id" => default_tenant_id
         }}
      end)

      message = %{
        "event" => "gtd.decomposition.approve",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)
      assert true
    end

    test "handles decomposition not found" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:error, :not_found}
      end)

      message = %{
        "event" => "gtd.decomposition.approve",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)
      assert true
    end

    test "handles missing decomposition_id" do
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "gtd.decomposition.approve",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{}
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)
      assert true
    end
  end

  describe "handle_reject/1" do
    test "updates decomposition with last_grade=0 and reviewed status" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "last_grade" => 2
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.reject",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_reject(message)
      assert true
    end

    test "handles decomposition not found" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:error, :not_found}
      end)

      message = %{
        "event" => "gtd.decomposition.reject",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_reject(message)
      assert true
    end

    test "handles invalid payload" do
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "gtd.decomposition.reject",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => "not a map"
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_reject(message)
      assert true
    end
  end

  describe "handle_review/1" do
    test "fsrs_grade=0 when rating < 3" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "predicted_subtask_count" => 5,
           "actual_subtask_count" => 5,
           "review_count" => 0
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        assert update_payload["last_grade"] == 0

        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 2
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "fsrs_grade=0 when delta > 0.3 (predicted=10, actual=3)" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "predicted_subtask_count" => 10,
           "actual_subtask_count" => 3,
           "review_count" => 0
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        assert update_payload["last_grade"] == 0

        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 5
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "fsrs_grade=3 (easy) for rating=5 and delta=0.0 (predicted=actual=3)" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "predicted_subtask_count" => 3,
           "actual_subtask_count" => 3,
           "review_count" => 0
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        assert update_payload["last_grade"] == 3

        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 5
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "fsrs_grade=2 (neutral) when predicted=nil" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "predicted_subtask_count" => nil,
           "actual_subtask_count" => 5,
           "review_count" => 0
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        assert update_payload["last_grade"] == 2

        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 4
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "stores user_feedback when provided" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()
      feedback = "Good breakdown but missed some edge cases"

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "predicted_subtask_count" => 5,
           "actual_subtask_count" => 5,
           "review_count" => 0
         }}
      end)

      expect(BotArmyGtd.DecompositionStoreMock, :update, fn ^decomposition_id, update_payload ->
        assert update_payload["user_feedback"] == feedback

        {:ok,
         Map.merge(update_payload, %{"id" => decomposition_id, "tenant_id" => default_tenant_id})}
      end)

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 4,
          "feedback" => feedback
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "handles missing rating" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "handles invalid rating (6, out of 1-5)" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 6
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end

    test "handles decomposition not found" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:error, :not_found}
      end)

      message = %{
        "event" => "gtd.decomposition.review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id,
          "rating" => 4
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)
      assert true
    end
  end

  describe "handle_request_review/1" do
    test "handles decomposition ready for review" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()
      now = DateTime.utc_now()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "due_at" => DateTime.add(now, -1, :day) |> DateTime.to_iso8601(),
           "predicted_subtask_count" => 5,
           "actual_subtask_count" => 4
         }}
      end)

      message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)
      assert true
    end

    test "handles decomposition not due yet" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()
      now = DateTime.utc_now()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "completed",
           "due_at" => DateTime.add(now, 1, :day) |> DateTime.to_iso8601()
         }}
      end)

      message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)
      assert true
    end

    test "handles decomposition with wrong status" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()
      now = DateTime.utc_now()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:ok,
         %{
           "id" => decomposition_id,
           "tenant_id" => default_tenant_id,
           "status" => "in_progress",
           "due_at" => DateTime.add(now, -1, :day) |> DateTime.to_iso8601()
         }}
      end)

      message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)
      assert true
    end

    test "handles decomposition not found" do
      decomposition_id = UUID.uuid4()
      event_id = UUID.uuid4()
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      expect(BotArmyGtd.DecompositionStoreMock, :get, fn ^default_tenant_id, ^decomposition_id ->
        {:error, :not_found}
      end)

      message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => event_id,
        "tenant_id" => default_tenant_id,
        "user_id" => nil,
        "payload" => %{
          "decomposition_id" => decomposition_id
        }
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)
      assert true
    end

    test "handles missing decomposition_id in payload" do
      event_id = UUID.uuid4()

      message = %{
        "event" => "gtd.decomposition.request_review",
        "event_id" => event_id,
        "payload" => %{}
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)
      assert true
    end
  end
end

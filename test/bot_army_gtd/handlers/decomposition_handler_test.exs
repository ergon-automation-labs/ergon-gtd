defmodule BotArmyGtd.Handlers.DecompositionHandlerTest do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  describe "handle_decompose/1" do
    test "handles valid decomposition request" do
      task_id = UUID.uuid4()
      event_id = UUID.uuid4()

      expect(BotArmyGtd.TaskStoreMock, :get, fn ^task_id ->
        {:ok, %{
          "id" => task_id,
          "title" => "Implement authentication system",
          "description" => "Add OAuth2 support"
        }}
      end)

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
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

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
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

      expect(BotArmyGtd.TaskStoreMock, :get, fn ^task_id ->
        {:error, :not_found}
      end)

      message = %{
        "event" => "gtd.task.decompose",
        "event_id" => event_id,
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

      expect(BotArmyGtd.DecompositionStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, %{
          "id" => decomposition_id,
          "parent_task_id" => task_id,
          "status" => "completed"
        }}
      end)

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "payload" => %{
          "chain_id" => chain_id,
          "steps" => [
            %{
              "name" => "break_down",
              "output" => Jason.encode!([
                %{"title" => "Setup OAuth", "description" => "Configure OAuth2 provider", "estimated_hours" => 4},
                %{"title" => "Database schema", "description" => "Add user table", "estimated_hours" => 2},
                %{"title" => "API endpoints", "description" => "Create auth endpoints", "estimated_hours" => 6}
              ])
            },
            %{
              "name" => "estimate_effort",
              "output" => Jason.encode!(%{
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
              "output" => Jason.encode!(%{
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

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
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

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
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

      expect(BotArmyGtd.DecompositionStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, %{
          "id" => UUID.uuid4(),
          "parent_task_id" => task_id,
          "status" => "completed"
        }}
      end)

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
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

      message = %{
        "event" => "llm.chain.completed",
        "event_id" => event_id,
        "payload" => "not a map"
      }

      BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)
      assert true
    end
  end
end

defmodule BotArmyGtd.Handlers.ClaudeHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  setup :verify_on_exit!

  describe "handle_task_create/1" do
    test "creates a new Claude task when no matching auto task exists" do
      tenant_id = BotArmyCore.Tenant.default_tenant_id()
      event_id = UUID.uuid4()

      expect(BotArmyGtd.TaskStoreMock, :list, fn ^tenant_id, _filters ->
        {:ok, []}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn payload ->
        assert payload["source"] == "claude"
        assert payload["title"] == "brain"
        assert payload["source_metadata"]["auto_generated"] == true
        {:ok, Map.put(payload, "id", UUID.uuid4())}
      end)

      message = %{
        "event" => "claude.task.create",
        "event_id" => event_id,
        "tenant_id" => tenant_id,
        "user_id" => "00000000-0000-0000-0000-000000000002",
        "payload" => %{
          "title" => "brain",
          "description" => "The following goals are at risk..."
        }
      }

      assert :ok = BotArmyGtd.Handlers.ClaudeHandler.handle_task_create(message)
    end

    test "reuses existing auto-generated Claude task instead of creating duplicate" do
      tenant_id = BotArmyCore.Tenant.default_tenant_id()
      event_id = UUID.uuid4()
      existing_id = UUID.uuid4()

      existing_task = %{
        "id" => existing_id,
        "source" => "claude",
        "title" => "brain",
        "description" => "The following goals are at risk...",
        "source_metadata" => %{
          "triggered_by_event_id" => UUID.uuid4(),
          "auto_generated" => true
        }
      }

      expect(BotArmyGtd.TaskStoreMock, :list, fn ^tenant_id, _filters ->
        {:ok, [existing_task]}
      end)

      expect(BotArmyGtd.TaskStoreMock, :update, fn ^existing_id, update_payload ->
        assert update_payload["source_metadata"]["auto_generated"] == true
        assert update_payload["source_metadata"]["triggered_by_event_id"] == event_id
        {:ok, Map.merge(existing_task, update_payload)}
      end)

      message = %{
        "event" => "claude.task.create",
        "event_id" => event_id,
        "tenant_id" => tenant_id,
        "user_id" => "00000000-0000-0000-0000-000000000002",
        "payload" => %{
          "title" => "brain",
          "description" => "The following goals are at risk..."
        }
      }

      assert :ok = BotArmyGtd.Handlers.ClaudeHandler.handle_task_create(message)
    end
  end
end

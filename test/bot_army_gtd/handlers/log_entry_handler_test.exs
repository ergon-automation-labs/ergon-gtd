defmodule BotArmyGtd.Handlers.LogEntryHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  setup :verify_on_exit!

  describe "handle_create/1" do
    test "successfully creates a log entry" do
      expected_entry = %{
        "id" => "test-entry-id",
        "body" => "Testing log entry",
        "category" => "work",
        "source" => "test",
        "file_written" => false,
        "occurred_at" => "2026-03-14T10:00:00",
        "created_at" => "2026-03-14T00:00:00"
      }

      expect(BotArmyGtd.MockLogEntryStore, :create, fn payload when is_map(payload) ->
        {:ok, expected_entry}
      end)

      expect(BotArmyGtd.MockLogEntryStore, :mark_file_written, fn _id ->
        {:ok, expected_entry}
      end)

      message = valid_create_message()
      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "creates log entry with body only (defaults applied)" do
      expected_entry = %{
        "id" => "test-entry-id",
        "body" => "Simple entry",
        "category" => "personal",
        "source" => "user",
        "file_written" => false,
        "occurred_at" => "2026-03-14T10:00:00",
        "created_at" => "2026-03-14T00:00:00"
      }

      expect(BotArmyGtd.MockLogEntryStore, :create, fn payload when is_map(payload) ->
        assert payload["body"] == "Simple entry"
        {:ok, expected_entry}
      end)

      expect(BotArmyGtd.MockLogEntryStore, :mark_file_written, fn _id ->
        {:ok, expected_entry}
      end)

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.log.create",
        "source" => "test",
        "triggered_by" => "test",
        "payload" => %{
          "body" => "Simple entry"
        }
      }

      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "validates required body field" do
      message =
        valid_create_message()
        |> put_in(["payload", "body"], nil)

      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "validates body must be string" do
      message =
        valid_create_message()
        |> put_in(["payload", "body"], 123)

      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "publishes events on success" do
      expected_entry = %{
        "id" => "test-entry-id",
        "body" => "Event test",
        "category" => "personal",
        "source" => "test",
        "file_written" => false,
        "occurred_at" => "2026-03-14T10:00:00"
      }

      expect(BotArmyGtd.MockLogEntryStore, :create, fn _payload ->
        {:ok, expected_entry}
      end)

      expect(BotArmyGtd.MockLogEntryStore, :mark_file_written, fn _id ->
        {:ok, expected_entry}
      end)

      message = valid_create_message()
      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "handles store creation failure" do
      expect(BotArmyGtd.MockLogEntryStore, :create, fn _payload ->
        {:error, :database_error}
      end)

      message = valid_create_message()
      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "creates entry with all optional fields" do
      expected_entry = %{
        "id" => "test-entry-id",
        "body" => "Full entry",
        "category" => "health",
        "tags" => ["exercise", "morning"],
        "task_id" => "task-123",
        "project" => "fitness",
        "source" => "tui",
        "file_written" => false,
        "occurred_at" => "2026-03-14T10:00:00"
      }

      expect(BotArmyGtd.MockLogEntryStore, :create, fn payload when is_map(payload) ->
        assert payload["category"] == "health"
        assert payload["tags"] == ["exercise", "morning"]
        assert payload["task_id"] == "task-123"
        assert payload["project"] == "fitness"
        {:ok, expected_entry}
      end)

      expect(BotArmyGtd.MockLogEntryStore, :mark_file_written, fn _id ->
        {:ok, expected_entry}
      end)

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.log.create",
        "source" => "test_client",
        "triggered_by" => "tui",
        "payload" => %{
          "body" => "Full entry",
          "category" => "health",
          "tags" => ["exercise", "morning"],
          "task_id" => "task-123",
          "project" => "fitness",
          "source" => "tui"
        }
      }

      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "creates entry with custom occurred_at" do
      expected_entry = %{
        "id" => "test-entry-id",
        "body" => "Past entry",
        "occurred_at" => "2026-03-10T14:30:00",
        "file_written" => false
      }

      expect(BotArmyGtd.MockLogEntryStore, :create, fn payload when is_map(payload) ->
        assert payload["occurred_at"] == "2026-03-10T14:30:00"
        {:ok, expected_entry}
      end)

      expect(BotArmyGtd.MockLogEntryStore, :mark_file_written, fn _id ->
        {:ok, expected_entry}
      end)

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.log.create",
        "source" => "test",
        "triggered_by" => "test",
        "payload" => %{
          "body" => "Past entry",
          "occurred_at" => "2026-03-10T14:30:00"
        }
      }

      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end

    test "creates entry with structured_data" do
      structured = %{
        "duration_minutes" => 30,
        "intensity" => "moderate"
      }

      expected_entry = %{
        "id" => "test-entry-id",
        "body" => "Workout",
        "structured_data" => structured,
        "file_written" => false,
        "occurred_at" => "2026-03-14T10:00:00"
      }

      expect(BotArmyGtd.MockLogEntryStore, :create, fn payload when is_map(payload) ->
        assert payload["structured_data"] == structured
        {:ok, expected_entry}
      end)

      expect(BotArmyGtd.MockLogEntryStore, :mark_file_written, fn _id ->
        {:ok, expected_entry}
      end)

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.log.create",
        "source" => "test",
        "triggered_by" => "test",
        "payload" => %{
          "body" => "Workout",
          "structured_data" => structured,
          "occurred_at" => "2026-03-14T10:00:00"
        }
      }

      assert :ok = BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)
    end
  end

  # Helper functions

  defp valid_create_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "gtd.log.create",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "test",
      "schema_version" => "1.0",
      "payload" => %{
        "body" => "Testing log entry",
        "category" => "work",
        "occurred_at" => "2026-03-14T10:00:00"
      }
    }
  end
end

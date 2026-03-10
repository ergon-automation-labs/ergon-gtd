defmodule BotArmyGtd.Handlers.InboxHandlerTest do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  describe "handle_add/1" do
    test "successfully adds inbox item and creates task" do
      inbox_payload = %{
        "raw_text" => "Buy milk",
        "source" => "user",
        "source_metadata" => %{}
      }

      expected_inbox_item = %{
        "id" => "inbox-1",
        "raw_text" => "Buy milk",
        "source" => "user",
        "source_metadata" => %{}
      }

      expected_task = %{
        "id" => "task-1",
        "title" => "Buy milk",
        "project_id" => "_inbox",
        "status" => "inbox"
      }

      expect(BotArmyGtd.InboxItemStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, expected_inbox_item}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, expected_task}
      end)

      expect(BotArmyGtd.InboxItemStoreMock, :mark_processed, fn "inbox-1" ->
        {:ok, %{"id" => "inbox-1", "status" => "processed"}}
      end)

      message = valid_add_message()
      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "returns error for missing raw_text field" do
      message =
        valid_add_message()
        |> put_in(["payload", "raw_text"], nil)

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "accepts custom source" do
      inbox_payload = %{
        "raw_text" => "Custom task",
        "source" => "job_bot",
        "source_metadata" => %{}
      }

      expected_inbox_item = %{
        "id" => "inbox-2",
        "raw_text" => "Custom task",
        "source" => "job_bot"
      }

      expected_task = %{
        "id" => "task-2",
        "title" => "Custom task",
        "project_id" => "_inbox"
      }

      expect(BotArmyGtd.InboxItemStoreMock, :create, fn _payload ->
        {:ok, expected_inbox_item}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _payload ->
        {:ok, expected_task}
      end)

      expect(BotArmyGtd.InboxItemStoreMock, :mark_processed, fn "inbox-2" ->
        {:ok, %{}}
      end)

      message =
        valid_add_message()
        |> put_in(["payload", "source"], "job_bot")

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "accepts source metadata" do
      expected_inbox_item = %{
        "id" => "inbox-3",
        "raw_text" => "Task with metadata"
      }

      expected_task = %{
        "id" => "task-3",
        "title" => "Task with metadata"
      }

      expect(BotArmyGtd.InboxItemStoreMock, :create, fn _payload ->
        {:ok, expected_inbox_item}
      end)

      expect(BotArmyGtd.TaskStoreMock, :create, fn _payload ->
        {:ok, expected_task}
      end)

      expect(BotArmyGtd.InboxItemStoreMock, :mark_processed, fn "inbox-3" ->
        {:ok, %{}}
      end)

      message =
        valid_add_message()
        |> put_in(["payload", "source_metadata"], %{"sender_id" => "123"})

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end
  end

  # Helper functions

  defp valid_add_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "gtd.inbox.add",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "payload" => %{
        "raw_text" => "Buy milk",
        "source" => "user"
      }
    }
  end
end

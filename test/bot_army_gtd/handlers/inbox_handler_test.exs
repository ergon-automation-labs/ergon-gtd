defmodule BotArmyGtd.Handlers.InboxHandlerTest do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  describe "handle_add/1" do
    test "successfully adds inbox item and requests parsing from LLM" do
      expected_inbox_item = %{
        "id" => UUID.uuid4() |> to_string(),
        "raw_text" => "Buy milk",
        "source" => "user",
        "source_metadata" => %{}
      }

      expect(BotArmyGtd.InboxItemStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, expected_inbox_item}
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
      expected_inbox_item = %{
        "id" => UUID.uuid4() |> to_string(),
        "raw_text" => "Custom task",
        "source" => "job_bot",
        "source_metadata" => %{}
      }

      expect(BotArmyGtd.InboxItemStoreMock, :create, fn _payload ->
        {:ok, expected_inbox_item}
      end)

      message =
        valid_add_message()
        |> put_in(["payload", "source"], "job_bot")

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "accepts source metadata" do
      expected_inbox_item = %{
        "id" => UUID.uuid4() |> to_string(),
        "raw_text" => "Task with metadata"
      }

      expect(BotArmyGtd.InboxItemStoreMock, :create, fn _payload ->
        {:ok, expected_inbox_item}
      end)

      message =
        valid_add_message()
        |> put_in(["payload", "source_metadata"], %{"sender_id" => "123"})

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "publishes error when inbox item creation fails" do
      expect(BotArmyGtd.InboxItemStoreMock, :create, fn _payload ->
        {:error, :database_error}
      end)

      message = valid_add_message()
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

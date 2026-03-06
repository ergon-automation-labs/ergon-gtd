defmodule BotArmyGtd.Handlers.InboxHandlerTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure Repo is configured
    {:ok, _} = BotArmyGtd.Repo.__adapter__.ensure_all_started(nil, [])
    :ok
  end

  describe "handle_add/1" do
    test "successfully adds inbox item and creates task" do
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
      message =
        valid_add_message()
        |> put_in(["payload", "source"], "job_bot")

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "accepts source metadata" do
      message =
        valid_add_message()
        |> put_in(["payload", "source_metadata"], %{"sender_id" => "123"})

      assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
    end

    test "handles various inbox item texts" do
      for text <- ["Buy milk", "Call dentist", "Review PRs"] do
        message = valid_add_message() |> put_in(["payload", "raw_text"], text)
        assert :ok = BotArmyGtd.Handlers.InboxHandler.handle_add(message)
      end
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
        "raw_text" => "Buy groceries",
        "source" => "user",
        "source_metadata" => %{}
      }
    }
  end
end

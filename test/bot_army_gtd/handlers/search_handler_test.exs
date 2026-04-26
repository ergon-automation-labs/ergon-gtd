defmodule BotArmyGtd.Handlers.SearchHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  setup do
    Mox.stub(BotArmyGtd.TaskStoreMock, :search, fn tenant_id, query, _filters, _pagination ->
      if tenant_id == "test-tenant" && query == "test" do
        {:ok, {[%{"id" => "1", "title" => "test task"}], 1}}
      else
        {:error, :search_failed}
      end
    end)

    :ok
  end

  test "handle_search with valid query" do
    message = %{
      "event_id" => "event-123",
      "event" => "gtd.task.search",
      "payload" => %{
        "query" => "test"
      },
      "tenant_id" => "test-tenant",
      "user_id" => "user-123"
    }

    {:ok, result} = BotArmyGtd.Handlers.SearchHandler.handle_search(message)

    assert is_map(result)
    assert Map.has_key?(result, "tasks")
    assert Map.has_key?(result, "total_count")
    assert Map.has_key?(result, "query")
  end

  test "handle_search with missing query field" do
    message = %{
      "event_id" => "event-123",
      "event" => "gtd.task.search",
      "payload" => %{},
      "tenant_id" => "test-tenant",
      "user_id" => "user-123"
    }

    {:error, reason} = BotArmyGtd.Handlers.SearchHandler.handle_search(message)

    assert reason == {:missing_field, "query"}
  end

  test "handle_search with empty query" do
    message = %{
      "event_id" => "event-123",
      "event" => "gtd.task.search",
      "payload" => %{
        "query" => ""
      },
      "tenant_id" => "test-tenant",
      "user_id" => "user-123"
    }

    {:error, reason} = BotArmyGtd.Handlers.SearchHandler.handle_search(message)

    assert reason == {:missing_field, "query"}
  end

  test "handle_search with invalid payload" do
    message = %{
      "event_id" => "event-123",
      "event" => "gtd.task.search",
      "payload" => "not a map",
      "tenant_id" => "test-tenant",
      "user_id" => "user-123"
    }

    {:error, reason} = BotArmyGtd.Handlers.SearchHandler.handle_search(message)

    assert reason == :invalid_payload
  end
end

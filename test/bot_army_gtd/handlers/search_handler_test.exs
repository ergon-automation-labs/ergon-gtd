defmodule BotArmyGtd.Handlers.SearchHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  setup do
    Mox.stub(BotArmyGtd.TaskStoreMock, :search, fn tenant_id, query, filters, _pagination ->
      cond do
        tenant_id == "test-tenant" && query == "test" ->
          {:ok, {[%{"id" => "1", "title" => "test task"}], 1}}

        tenant_id == "test-tenant" && query == "*" && Map.get(filters, "no_project") == true ->
          {:ok, {[%{"id" => "2", "title" => "orphan task"}], 1}}

        true ->
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

  test "handle_search with no_project allows omitted query (normalized to *)" do
    message = %{
      "event_id" => "event-456",
      "event" => "gtd.task.search",
      "payload" => %{
        "filters" => %{"no_project" => true}
      },
      "tenant_id" => "test-tenant",
      "user_id" => "user-123"
    }

    {:ok, result} = BotArmyGtd.Handlers.SearchHandler.handle_search(message)

    assert result["query"] == "*"
    assert hd(result["tasks"])["id"] == "2"
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

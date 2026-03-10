defmodule BotArmyGtd.Handlers.InboxParsingHandlerTest do
  use ExUnit.Case

  alias BotArmyGtd.Handlers.InboxParsingHandler

  defmodule TestTaskStoreMock do
    def create(payload) do
      Process.get({:task_store_mock, :create}, {:ok, payload |> Map.put("id", UUID.uuid4() |> to_string())})
    end

    def get(item_id) do
      Process.get({:task_store_mock, :get}, {:ok, %{"id" => item_id}})
    end

    def list do
      Process.get({:task_store_mock, :list}, {:ok, []})
    end

    def update(item_id, payload) do
      Process.get({:task_store_mock, :update}, {:ok, payload |> Map.put("id", item_id)})
    end

    def archive(item_id) do
      Process.get({:task_store_mock, :archive}, {:ok, %{"id" => item_id}})
    end

    def clear do
      :ok
    end
  end

  setup do
    Application.put_env(:bot_army_gtd, :task_store, TestTaskStoreMock)

    on_exit(fn ->
      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    end)

    :ok
  end

  test "creates task from parsed inbox data" do
    Process.put(
      {:task_store_mock, :create},
      {:ok, %{
        "id" => "task-1",
        "title" => "Call dentist",
        "priority" => "high",
        "due_date" => "2026-03-18T14:00Z"
      }}
    )

    message = %{
      "event_id" => "parse-event-id",
      "payload" => %{
        "structured_data" => %{
          "title" => "Call dentist",
          "priority" => "high",
          "due_date" => "2026-03-18T14:00Z"
        },
        "inbox_item_id" => "inbox-1",
        "source" => "user",
        "source_metadata" => %{}
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "extracts all task fields from parsed data" do
    Process.put(
      {:task_store_mock, :create},
      {:ok, %{
        "id" => "task-2",
        "title" => "Plan team offsite",
        "description" => "3-day team building event",
        "project_id" => "Team Events",
        "priority" => "high",
        "due_date" => "2026-04-15T09:00Z",
        "tags" => ["planning", "team"]
      }}
    )

    message = %{
      "event_id" => "parse-event-id",
      "payload" => %{
        "structured_data" => %{
          "title" => "Plan team offsite",
          "description" => "3-day team building event",
          "project" => "Team Events",
          "priority" => "high",
          "due_date" => "2026-04-15T09:00Z",
          "tags" => ["planning", "team"]
        },
        "inbox_item_id" => "inbox-2"
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "uses defaults when optional fields missing" do
    Process.put(
      {:task_store_mock, :create},
      {:ok, %{"id" => "task-3"}}
    )

    message = %{
      "event_id" => "parse-event-id",
      "payload" => %{
        "structured_data" => %{
          "title" => "Simple task"
        },
        "inbox_item_id" => "inbox-3"
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "publishes error when structured_data missing" do
    message = %{
      "event_id" => "parse-event-id",
      "payload" => %{
        "inbox_item_id" => "inbox-4"
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "publishes error when structured_data not a map" do
    message = %{
      "event_id" => "parse-event-id",
      "payload" => %{
        "structured_data" => "not a map",
        "inbox_item_id" => "inbox-5"
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "publishes error when store creation fails" do
    Process.put(
      {:task_store_mock, :create},
      {:error, :store_error}
    )

    message = %{
      "event_id" => "parse-event-id",
      "payload" => %{
        "structured_data" => %{
          "title" => "Task"
        },
        "inbox_item_id" => "inbox-6"
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "publishes error when payload is invalid" do
    message = %{
      "event_id" => "parse-event-id",
      "payload" => nil
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end

  test "correlates response with original event using inbox_item_id" do
    Process.put(
      {:task_store_mock, :create},
      {:ok, %{"id" => "task-8", "inbox_item_id" => "inbox-8"}}
    )

    message = %{
      "event_id" => "original-parse-request-id",
      "payload" => %{
        "structured_data" => %{
          "title" => "Correlated task"
        },
        "inbox_item_id" => "inbox-8"
      }
    }

    assert :ok = InboxParsingHandler.handle_parse(message)
  end
end

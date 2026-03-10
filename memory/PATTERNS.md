# bot_army_gtd Code Patterns & Conventions

## Handler Pattern

All handlers follow the validation → processing → publishing pattern defined in parent GOVERNANCE.md#handler-pattern.

### Structure

All GTD handlers follow this standard structure:

```elixir
defmodule BotArmyGtd.Handlers.InboxHandler do
  @moduledoc """
  Handles inbox-related events for the GTD bot.

  Processes incoming messages:
  - `gtd.inbox.add` - Process raw inbox text into structured item

  Dependencies:
  - BotArmyGtd.InboxItemStore
  - BotArmyGtd.NATS.Publisher
  """

  require Logger

  # Dependency injection
  defp inbox_store do
    Application.get_env(:bot_army_gtd, :inbox_store, BotArmyGtd.InboxItemStore)
  end

  def handle_inbox_add(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_payload(payload) do
      :ok -> process_inbox_add(payload, event_id, message)
      {:error, reason} -> publish_error(event_id, reason, "Invalid payload")
    end
  end

  # Private validation
  defp validate_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "text") do
      :ok
    end
  end

  defp validate_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  # Private processing
  defp process_inbox_add(payload, event_id, _message) do
    case inbox_store().create(%{
      "text" => payload["text"],
      "status" => "pending"
    }) do
      {:ok, item} ->
        Logger.info("Inbox item added: event_id=#{event_id}, item_id=#{item["id"]}")
        publish_success(item, event_id)

      {:error, reason} ->
        Logger.error("Failed to add inbox item: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to store item")
    end
  end

  # Private publishing
  defp publish_success(item, event_id) do
    event = %{
      "event" => "gtd.inbox.processed",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "item" => item,
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event) do
      :ok -> Logger.debug("Published inbox processed event")
      {:error, reason} -> Logger.error("Failed to publish: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message) do
    event = %{
      "event" => "gtd.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_gtd",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "gtd.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyGtd.NATS.Publisher.publish(event) do
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end
```

### Key Points

- **Validation**: Returns `:ok` or `{:error, reason}` tuple
- **Processing**: Calls injected store, handles both success and error cases
- **Publishing**: Always includes `triggered_by_event_id` for correlation
- **Error Handling**: Always publishes `gtd.error` event with original event_id
- **Logging**: Info on success, error on failure, debug on publishing

---

## Store Pattern

All stores (TaskStore, ProjectStore, InboxItemStore) follow the parent Store Pattern with consistent interface:

### Standard Interface

```elixir
defmodule BotArmyGtd.TaskStore do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Gracefully handle DB unavailability during startup
    state = try do
      BotArmyGtd.Repo.all(BotArmyGtd.Task)
      |> Enum.reduce(%{}, fn item, acc ->
        Map.put(acc, item.id |> to_string(), task_to_map(item))
      end)
    rescue
      _ ->
        Logger.warning("DB unavailable, starting with empty state")
        %{}
    end
    {:ok, state}
  end

  # Create
  def create(payload) do
    GenServer.call(__MODULE__, {:create, payload})
  end

  # Read
  def get(item_id) do
    GenServer.call(__MODULE__, {:get, item_id})
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  # Update
  def update(item_id, payload) do
    GenServer.call(__MODULE__, {:update, item_id, payload})
  end

  # Archive (soft delete)
  def archive(item_id) do
    GenServer.call(__MODULE__, {:archive, item_id})
  end

  # Test helper
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Handle calls (private implementation)
  @impl true
  def handle_call({:create, payload}, _from, state) do
    item = %{
      "id" => UUID.uuid4() |> to_string(),
      "status" => "active"
    } |> Map.merge(payload)

    new_state = Map.put(state, item["id"], item)
    persist_to_db(item)

    {:reply, {:ok, item}, new_state}
  end

  # ... similar for get, update, archive, list, clear
end
```

### Key Points

- **GenServer pattern**: Manages state concurrently
- **Consistent interface**: All stores have same 6 functions (create, get, list, update, archive, clear)
- **In-memory + persistent**: Map for fast reads, Ecto for durability
- **Graceful DB fallback**: Logs warning if DB unavailable on startup, continues with empty state
- **Behavior-based mocking**: Implements BehaviourModule for test injection

---

## Testing Pattern: Handler with Mocks

All handler tests use Application.put_env/3 injection for store mocking:

```elixir
defmodule BotArmyGtd.Handlers.TaskHandlerTest do
  use ExUnit.Case

  # Define inline mock module
  defmodule TestTaskStoreMock do
    def create(payload) do
      Process.get({:task_store_mock, :create}, {:ok, payload |> Map.put("id", "test-id")})
    end

    def get(item_id) do
      Process.get({:task_store_mock, :get}, {:ok, %{"id" => item_id}})
    end

    def update(item_id, payload) do
      Process.get({:task_store_mock, :update}, {:ok, payload |> Map.put("id", item_id)})
    end

    # ... other callbacks
  end

  setup do
    # Inject mock before test
    Application.put_env(:bot_army_gtd, :task_store, TestTaskStoreMock)

    # Restore after test
    on_exit(fn ->
      Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    end)

    :ok
  end

  test "handler creates task when store succeeds" do
    # Configure mock per-test
    Process.put({:task_store_mock, :create}, {:ok, %{"id" => "test-id", "title" => "Test task"}})

    message = %{
      "event_id" => "test-event-id",
      "payload" => %{"title" => "Test task"}
    }

    assert :ok = TaskHandler.handle_task_create(message)
  end

  test "handler publishes error when store fails" do
    Process.put({:task_store_mock, :create}, {:error, :store_error})

    message = %{
      "event_id" => "test-event-id",
      "payload" => %{"title" => "Test task"}
    }

    assert :ok = TaskHandler.handle_task_create(message)
  end

  test "handler validates payload" do
    message = %{
      "event_id" => "test-event-id",
      "payload" => %{}  # Missing required title field
    }

    assert :ok = TaskHandler.handle_task_create(message)
  end
end
```

### Key Points

- **Mock per store**: Define inline TestTaskStoreMock, TestProjectStoreMock, etc.
- **Per-test config**: Use Process.put to configure mock response for each test
- **No DB access**: Tests don't connect to database
- **Restore on exit**: Use on_exit callback to reset Application config
- **No assertions on publishing**: Publishing side-effects verified through logs

---

## NATS Message Subject Naming

All GTD messages follow hierarchical pattern: `<domain>.<entity>.<action>`

### Inbox Messages

**Incoming:**
- `gtd.inbox.add` - Process raw inbox text

**Outgoing:**
- `events.gtd.inbox.processed` - Inbox item processed

### Task Messages

**Incoming:**
- `gtd.task.create` - Create new task
- `gtd.task.update` - Update existing task
- `gtd.task.complete` - Mark task as complete

**Outgoing:**
- `events.gtd.task.created` - Task created successfully
- `events.gtd.task.updated` - Task updated successfully
- `events.gtd.task.completed` - Task marked complete

### Project Messages

**Incoming:**
- `gtd.project.create` - Create new project
- `gtd.project.update` - Update existing project

**Outgoing:**
- `events.gtd.project.created` - Project created successfully
- `events.gtd.project.updated` - Project updated successfully

### Error Messages

**Outgoing (from any handler):**
- `events.gtd.error` - Any operation failed

---

## Dependency Injection Pattern

All external dependencies (stores, LLM client, etc.) injected via Application.get_env/3:

```elixir
# In handler
defp task_store do
  Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
end

defp llm_client do
  Application.get_env(:bot_army_gtd, :llm_client, BotArmyLlm.LlmClient)
end

# In tests
setup do
  Application.put_env(:bot_army_gtd, :task_store, TestTaskStoreMock)
  Application.put_env(:bot_army_gtd, :llm_client, TestLlmClientMock)
  :ok
end
```

### Benefits

- **No coupling to implementations**: Handler calls `task_store()`, not directly to BotArmyGtd.TaskStore
- **Easy testing**: Inject mocks for any test
- **Cross-repo dependencies**: Can inject LLM client for llm.response.parse calls
- **Environment-specific**: Different impls in dev/prod/test

---

## Phase 1: Inbox Parsing Integration (v0.2.0)

When implementing the LLM integration for inbox parsing:

### New Handler: InboxParsingHandler

```elixir
defmodule BotArmyGtd.Handlers.InboxParsingHandler do
  @moduledoc """
  Parses raw inbox text into structured task fields.

  Calls llm.response.parse to extract:
  - title: Task title
  - description: Task description
  - project: Project name
  - priority: Task priority (low, normal, high)
  - due_date: ISO8601 date string
  - tags: Array of tag strings

  Dependencies:
  - BotArmyLlm.LlmClient (injected via Application.get_env)
  - BotArmyGtd.TaskStore
  """

  require Logger

  defp llm_client do
    Application.get_env(:bot_army_gtd, :llm_client, BotArmyLlm.LlmClient)
  end

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
  end

  def handle_inbox_parse(message) do
    # Calls llm.response.parse event to extract structured fields
    # Creates task from parsed result
    # Publishes gtd.task.created on success
    # Publishes gtd.error on failure
  end
end
```

### Schema for Extraction

```elixir
output_schema = %{
  "type" => "object",
  "required" => ["title"],
  "properties" => %{
    "title" => %{"type" => "string"},
    "description" => %{"type" => "string"},
    "project" => %{"type" => "string"},
    "priority" => %{"enum" => ["low", "normal", "high"]},
    "due_date" => %{"type" => "string"},
    "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
  }
}
```

### Example Flow

```
User adds inbox item: "Call dentist next Tuesday before 2pm"
  ↓
InboxHandler receives gtd.inbox.add
  ↓
InboxHandler publishes llm.response.parse event
  ↓
LLM bot receives, extracts structured fields:
  {
    "title": "Call dentist",
    "priority": "high",
    "due_date": "2026-03-18T14:00Z",
    "tags": ["phone"]
  }
  ↓
LLM bot publishes llm.response.parsed
  ↓
GTD bot receives, creates structured task via TaskStore
  ↓
GTD bot publishes gtd.task.created
```

### Testing Approach

```elixir
test "parsing handler extracts task fields from inbox text" do
  # Mock LLM client to return structured data
  Process.put({:llm_client_mock, :parse}, {:ok, %{
    "title" => "Call dentist",
    "priority" => "high",
    "due_date" => "2026-03-18T14:00Z"
  }})

  # Mock task store to accept created task
  Process.put({:task_store_mock, :create}, {:ok, %{"id" => "task-1"}})

  message = %{
    "event_id" => "llm-event-id",
    "payload" => %{
      "structured_data" => %{
        "title" => "Call dentist",
        "priority" => "high"
      }
    }
  }

  assert :ok = InboxParsingHandler.handle_inbox_parse(message)
end
```

---

## Message History Format (for Future Use)

When implementing Phase 3 (TaskClarificationHandler with multi-turn conversations), message history will follow this format:

```elixir
[
  %{"role" => "user", "content" => "I have an ambiguous task: 'Review project updates'. What project?"},
  %{"role" => "assistant", "content" => "Which of these projects? A) Mobile App, B) Infrastructure, C) Docs"},
  %{"role" => "user", "content" => "Mobile App"},
  %{"role" => "assistant", "content" => "Got it. Task created: 'Review Mobile App updates'"}
]
```


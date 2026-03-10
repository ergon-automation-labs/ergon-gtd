# bot_army_gtd Architecture Decisions

## Decision: Mox Testing for Store Isolation

**Date:** 2026-03-09
**Status:** Accepted
**Modules:** TaskStore, ProjectStore, InboxItemStore, all handlers
**Version:** 0.1.1+

**Problem:**
Handler tests were calling real stores (TaskStore, ProjectStore, InboxItemStore) which tried to connect to PostgreSQL on port 30003. SSH tunnel unavailable during local test runs, blocking test execution. Pre-push hook couldn't run tests, preventing releases.

**Decision:**
Implement Mox pattern for all stores:
1. Create behaviour modules (TaskStoreBehaviour, ProjectStoreBehaviour, InboxItemStoreBeha behaviour)
2. Update stores to implement behaviours
3. Inject mocks in test environment via Application.put_env/3
4. Update handlers to use injected stores at runtime

**Rationale:**
- Proper test isolation (no database dependency)
- Matches parent testing strategy (see GOVERNANCE.md#testing-patterns)
- Enables local test execution without infrastructure setup
- Pre-push hook can now run tests successfully

**Alternatives Considered:**
- Skip tests in pre-push hook - rejected: loses quality gate
- Database transactions + rollback - rejected: still requires DB connection
- Real DB in test with Docker - rejected: overhead, slow startup

**Implementation:**
```elixir
# Create behaviour
defmodule BotArmyGtd.TaskStoreBehaviour do
  @callback create(map()) :: {:ok, map()} | {:error, any()}
  @callback get(String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback list() :: {:ok, [map()]}
  @callback update(String.t(), map()) :: {:ok, map()} | {:error, any()}
  @callback archive(String.t()) :: {:ok, map()} | {:error, any()}
  @callback clear() :: :ok
end

# In handlers
defp task_store do
  Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
end

# In tests
defmodule TestTaskStoreMock do
  def create(payload), do: Process.get({:task_store_mock, :create}, {:ok, payload})
  # etc.
end

setup do
  Application.put_env(:bot_army_gtd, :task_store, TestTaskStoreMock)
  on_exit(fn -> Application.put_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore) end)
  :ok
end
```

**Impact:**
- 11/11 tests passing (v0.1.1)
- Zero database access during test runs
- Pre-push hook can execute tests successfully
- Releases can be created and published

**Related:**
- Parent GOVERNANCE.md → Testing Patterns → Handler Testing (with Mocks)
- Parent GOVERNANCE.md → Core Principles → Dependency Injection

---

## Decision: LLM Integration Roadmap (3-Phase Approach)

**Date:** 2026-03-10
**Status:** Planned
**Related Repo:** bot_army_llm v0.5.2+
**Version:** 0.2.0+ (Phase 1)

**Problem:**
Raw inbox text captured as-is. No structure extraction (title, project, priority, due date, tags). Users must manually organize tasks after adding them.

**Decision:**
Integrate with LLM bot to add intelligence across three phases:

### Phase 1: Inbox Parsing (v0.2.0, HIGH PRIORITY)
- New InboxParsingHandler
- Calls llm.response.parse to extract task fields from raw text
- Schema: title, description, project, priority, due_date, tags
- Example: "Call dentist next Tuesday before 2pm" → structured task with due date + priority

### Phase 2: Task Decomposition (v0.3.0, MEDIUM PRIORITY)
- New TaskDecompositionHandler
- Calls llm.inference.chain for multi-step breakdown
- Breaks complex tasks into subtasks with dependencies
- Example: "Implement auth system" → 5-8 subtasks with effort estimates

### Phase 3: Task Clarification (v0.4.0, MEDIUM PRIORITY)
- New TaskClarificationHandler
- Calls llm.inference.converse for multi-turn conversation
- Clarifies ambiguous tasks through conversation
- Example: "Review project updates" → Conversation to determine which project

**Rationale:**
- LLM bot fully tested, ready to consume
- GTD bot has existing handler infrastructure for new features
- Phase approach allows incremental rollout and traffic testing
- Each phase increases sophistication without breaking existing flow

**Traffic Impact:**
With 5 users, 250 tasks/week:
- Phase 1: 250 llm.response.parse calls/week
- Phase 2 (optional): 25 llm.inference.chain calls/week
- Phase 3 (optional): 10 llm.inference.converse calls/week
- Total: 285 LLM bot calls/week (real system traffic)

**Testing Strategy:**
- Mox for LLM client dependency injection
- Test with mocked llm.response.parse responses
- 8 tests per handler (parsing, validation, error cases)

**Related:**
- Bot Army LLM Integration → memory/GTD_LLM_INTEGRATION.md
- Parent GOVERNANCE.md → Cross-Repo References

---

## Decision: Standard Store Pattern for Data Persistence

**Date:** 2026-03-09
**Status:** Accepted
**Modules:** TaskStore, ProjectStore, InboxItemStore
**Version:** 0.1.0+

**Problem:**
Handlers need to persist data (tasks, projects, inbox items). Data must survive restarts. Multiple stores with different interfaces created code duplication.

**Decision:**
Implement standardized Store pattern following parent GOVERNANCE.md#store-pattern:
- GenServer-based in-memory + PostgreSQL persistence
- Consistent interface across all stores (create, get, list, update, archive, clear)
- Graceful DB fallback on startup (log warning, continue with empty state)
- Mocking-friendly for tests

**Rationale:**
- Parent pattern is proven, documented, follows Erlang conventions
- In-memory cache provides fast reads without DB round-trips
- Graceful degradation if DB unavailable
- Standard interface reduces cognitive load
- Behavior-based mocking enables test isolation

**Stores Created:**
1. **TaskStore** - Manages GTD tasks (title, description, project, priority, due_date)
2. **ProjectStore** - Manages GTD projects (name, description, status)
3. **InboxItemStore** - Manages unprocessed inbox items (raw text, processing status)

**Impact:**
- All three stores follow identical pattern
- Easy to understand and maintain
- Easy to mock for tests
- Supports graceful degradation

**Related:**
- Parent GOVERNANCE.md → Store Pattern → Standard Store Interface
- Parent GOVERNANCE.md → Store Pattern → Initialization Pattern

---

## Decision: NATS Message Subject Naming

**Date:** 2026-03-09
**Status:** Accepted
**Scope:** All incoming and outgoing messages
**Version:** 0.1.0+

**Problem:**
Multiple message types need clear, consistent naming. Need to distinguish between different operations on same entity (task.create vs task.update vs task.complete).

**Decision:**
Use hierarchical NATS subject naming: `<domain>.<entity>.<action>`

**Incoming Messages:**
```
gtd.inbox.add           → InboxHandler processes raw text
gtd.task.create         → TaskHandler creates task
gtd.task.update         → TaskHandler updates task
gtd.project.create      → ProjectHandler creates project
```

**Outgoing Messages:**
```
events.gtd.inbox.processed    → From InboxHandler
events.gtd.task.created       → From TaskHandler
events.gtd.task.updated       → From TaskHandler
events.gtd.project.created    → From ProjectHandler
```

**Rationale:**
- Hierarchical structure mirrors domain concepts
- Clear routing logic (easy to implement consumer pattern matching)
- Consistent with bot_army_llm naming (llm.prompt.submit, llm.inference.chain)
- Matches parent GOVERNANCE.md examples

**Related:**
- Parent GOVERNANCE.md → NATS Message Pattern

---

## Decision: Asynchronous LLM-Powered Inbox Parsing (v0.2.0)

**Date:** 2026-03-10
**Status:** Implemented
**Modules:** InboxHandler, InboxParsingHandler, Consumer
**Version:** 0.2.0+

**Problem:**
Inbox items captured as raw text, users must manually structure (add title, project, priority, due date). No intelligent extraction. Real system traffic testing blocked - need LLM bot integration to generate meaningful event flow.

**Decision:**
Implement asynchronous inbox text parsing using LLM bot:

1. **InboxHandler** (gtd.inbox.add):
   - Accepts raw text from user/system
   - Creates inbox item (raw_text + source metadata)
   - Publishes llm.response.parse request with:
     - Raw text to parse
     - JSON schema (title, description, project, priority, due_date, tags)
     - inbox_item_id for correlation

2. **InboxParsingHandler** (llm.response.parsed):
   - Listens for parsed responses from LLM bot
   - Validates structured_data (required: title)
   - Creates task with extracted fields + defaults
   - Links to original inbox_item_id
   - Publishes gtd.task.created

3. **Consumer** changes:
   - Subscribe to llm.response.parsed
   - Route to InboxParsingHandler

**Rationale:**
- Enables LLM intelligence for task extraction (NLP-based structure inference)
- Asynchronous flow maintains event-driven architecture
- Generates realistic system traffic (250+ LLM calls/week with 5 users)
- Allows future optimization (queueing, prioritization, batching)
- Loose coupling: GTD doesn't depend on LLM response timing

**Alternatives Considered:**
- Synchronous LLM call - rejected: breaks event-driven pattern, tight coupling
- Direct task creation without LLM - rejected: no traffic generation, loses intelligence
- Batch parsing - rejected: adds complexity, skip for Phase 1

**Traffic Impact:**
- v0.2.0: Every gtd.inbox.add → llm.response.parse call
- 250 inbox items/week × 5 users = 250 LLM calls/week
- Thoroughly exercises bot_army_llm v0.5.2 ResponseHandler

**Testing:**
- 8 comprehensive InboxParsingHandler tests
- Mock LLM responses with Process.put pattern
- Test validation, error cases, field extraction, defaults, correlation

**Future Phases:**
- Phase 2 (v0.3.0): Task decomposition (llm.inference.chain)
- Phase 3 (v0.4.0): Task clarification (llm.inference.converse)

**Related:**
- Parent GOVERNANCE.md → Cross-Repo References (GTD × LLM integration)
- bot_army_llm/CLAUDE.md → ResponseHandler (llm.response.parse, llm.response.parsed)
- bot_army_llm v0.5.2 - Must deploy before this
- memory/GTD_LLM_INTEGRATION.md (overall roadmap)


# BotArmyGtd

GTD (Getting Things Done) bot implementation for the Bot Army ecosystem.

**Current Version:** 0.2.0

**Status:** Inbox text parsing with LLM intelligence enabled

Manages task inbox, projects, and context-based organization with intelligent text parsing powered by the LLM bot.

## Features

- **Inbox Management** - Capture raw text, automatically extract structured tasks
- **Intelligent Parsing** - Uses LLM (bot_army_llm) to extract: title, description, project, priority, due_date, tags
- **Task Organization** - Projects, contexts, priority levels, due dates
- **State Transitions** - Task lifecycle: inbox → active → completed/deferred/deleted

## Getting Started

```bash
mix deps.get
mix test                        # Run all 20 tests
mix test --cover                # With coverage report
mix credo                        # Linting
```

## NATS Message Interface

### Incoming Messages

| Subject | Handler | Purpose |
|---------|---------|---------|
| `gtd.inbox.add` | InboxHandler | Add raw text to inbox, triggers LLM parsing |
| `gtd.task.create` | TaskHandler | Create task directly |
| `gtd.task.update` | TaskHandler | Update task properties |
| `gtd.task.complete` | TaskHandler | Mark task complete |
| `gtd.task.command.defer` | TaskHandler | Defer task |
| `gtd.task.command.delete` | TaskHandler | Delete task |
| `gtd.project.create` | ProjectHandler | Create project |
| `gtd.project.update` | ProjectHandler | Update project |
| `llm.response.parsed` | InboxParsingHandler | Receive parsed inbox text (Phase 1) |

### Outgoing Messages

| Event | Source | Payload |
|-------|--------|---------|
| `gtd.inbox.item.added` | InboxHandler | Created inbox item with raw text |
| `gtd.task.created` | InboxParsingHandler / TaskHandler | Created task (structured if from inbox parsing) |
| `gtd.task.updated` | TaskHandler | Updated task |
| `gtd.task.completed` | TaskHandler | Task marked complete |
| `gtd.project.created` | ProjectHandler | Created project |
| `gtd.project.updated` | ProjectHandler | Updated project |
| `gtd.error` | Any handler | Error during processing |

## Architecture

### Request Flow (Phase 1: Inbox Parsing)

```
User input (raw text)
  ↓
gtd.inbox.add
  ↓
InboxHandler
  ├── Create inbox item
  └── Publish llm.response.parse to LLM bot
        ↓ [async via NATS]
  LLM bot ResponseHandler
  ├── Extract: title, description, project, priority, due_date, tags
  └── Publish llm.response.parsed
        ↓
GTD Consumer
  ↓
InboxParsingHandler
  ├── Validate parsed data
  ├── Create task with extracted fields
  └── Publish gtd.task.created
```

### Key Modules

- **BotArmyGtd.NATS.Consumer** - Routes messages to handlers
- **BotArmyGtd.Handlers.InboxHandler** - Accepts raw text, requests parsing
- **BotArmyGtd.Handlers.InboxParsingHandler** - Creates tasks from parsed text (v0.2.0+)
- **BotArmyGtd.Handlers.TaskHandler** - Task creation/updates
- **BotArmyGtd.Handlers.ProjectHandler** - Project management
- **BotArmyGtd.{TaskStore, ProjectStore, InboxItemStore}** - GenServer-based persistence with DB fallback

## Phase Progress

### Phase 1: Inbox Parsing ✅ DONE (v0.2.0)
- Asynchronous text parsing via LLM bot
- JSON extraction schema: title, description, project, priority, due_date, tags
- Request correlation via inbox_item_id
- 8 comprehensive tests for InboxParsingHandler

### Phase 2: Task Decomposition 🔄 PLANNED (v0.3.0)
- Multi-step breakdown of complex tasks
- Uses llm.inference.chain for step-by-step refinement
- Creates sub-task relationships with dependencies

### Phase 3: Task Clarification 🔄 PLANNED (v0.4.0)
- Multi-turn conversation for ambiguous tasks
- Uses llm.inference.converse for interactive clarification
- Maintains conversation history per task

## Expected Traffic

With realistic GTD usage (5 users, 50 tasks/user/week):

- **Phase 1**: 250 llm.response.parse calls/week
- **Phase 2** (optional): 25 llm.inference.chain calls/week
- **Phase 3** (optional): 10 llm.inference.converse calls/week
- **Total**: ~285 LLM bot interactions/week from GTD bot

This provides realistic system traffic for testing bot_army_llm under production-like conditions.

## Dependencies

- `bot_army_core` - Core NATS decoder and envelope handling
- `bot_army_runtime` - Shared persistence and NATS utilities
- `bot_army_llm` - LLM services for text parsing (v0.5.2+ required for Phase 1)
- `nats` - NATS client library
- `jason` - JSON encoding/decoding
- `logger_json` - JSON logging
- `ecto` - Database ORM
- `postgrex` - PostgreSQL adapter

## Configuration

### Environment Variables

- `NATS_SERVERS` - NATS broker URLs (default: "nats://localhost:4222")
- `DATABASE_URL` - PostgreSQL connection string
- `MIX_ENV` - Environment (dev, test, prod)

### Database

PostgreSQL required for task persistence. Migrations auto-run on startup.

### NATS

Requires running NATS broker. Tests use in-memory NATS mock.

## Testing

```bash
# All tests
mix test

# Specific test file
mix test test/bot_army_gtd/handlers/inbox_parsing_handler_test.exs

# With coverage
mix test --cover

# Watch mode (requires mix_test_watch)
mix test.watch
```

**Test Strategy:** Uses Mox for store mocking, Application.put_env for dependency injection, no database access during tests.

## Deployment

Via Salt from `bot_army_infra`:

```bash
cd ../bot_army_infra
make deploy-bot BOT=gtd
```

Requires:
1. bot_army_core deployed
2. bot_army_schemas_gtd deployed
3. NATS broker available
4. PostgreSQL available

## Related Repositories

- `bot_army_schemas_gtd` - GTD message schemas
- `bot_army_llm` - LLM services (required for Phase 1+)
- `bot_army_core` - Core library
- `bot_army_runtime` - Runtime utilities
- `bot_army_infra` - Deployment infrastructure

## Development

See `/CLAUDE.md` for Claude Code development guidance and `/memory/DECISIONS.md` for architecture decisions.

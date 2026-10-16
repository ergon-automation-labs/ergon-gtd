# BotArmyGtd

GTD (Getting Things Done) bot implementation for the Bot Army ecosystem.

**Current Version:** 0.8.0

**Status:** Inbox text parsing with LLM intelligence enabled

Manages task inbox, projects, and context-based organization with intelligent text parsing powered by the LLM bot.

## Features

- **Inbox Management** - Capture raw text, automatically extract structured tasks
- **Intelligent Parsing** - Uses LLM (bot_army_llm) to extract: title, description, project, priority, due_date, tags
- **Task Organization** - Projects, contexts, priority levels, due dates
- **State Transitions** - Task lifecycle: inbox → active → completed/deferred/deleted
- **A coach that only reads (§62)** - `gtd.coach.chat` answers a question about her own
  system, grounded in facts this bot reads itself: her active projects, her open tasks grouped
  by project, and her inbox. It may use exactly one look-up across her project docs
  (`LOOKUP docs "..."`) or her own PARA files (`LOOKUP para "..."`). It is read-only: it
  names nothing it was not shown, it does not rank her tasks, and it does not decide what she
  should do next. A slow answer is backgrounded on the local model and woken by
  `events.llm.job.completed` rather than lost (§61, ported here). Her PARA files are searched one
  folder at a time — `projects`, `areas`, `inbox`, `archive`, and last the much larger
  `resources` — stopping at the first folder that answers, because a whole-tree search there takes
  about a minute and a timed-out one returns nothing at all, not the matches it had already found.

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
| `gtd.task.decompose` | DecompositionHandler | Request multi-step task decomposition (Phase 2) |
| `gtd.project.create` | ProjectHandler | Create project |
| `gtd.project.update` | ProjectHandler | Update project |
| `llm.response.parsed` | InboxParsingHandler | Receive parsed inbox text (Phase 1) |
| `llm.chain.completed` | DecompositionHandler | Receive decomposition chain results (Phase 2) |
| `gtd.coach.chat` | CoachChatHandler | Ask about her own system — projects, tasks, inbox, one optional look-up (§62). **Read-only.** |
| `gtd.graph.series` | GraphHandler | Every graph this bot can draw from the task log, with the points behind each one (§67). **Read-only.** |
| `events.llm.job.completed` | Consumer (JobBell) | Wake a backgrounded coach job (§62) |

### Outgoing Messages

| Event | Source | Payload |
|-------|--------|---------|
| `gtd.inbox.item.added` | InboxHandler | Created inbox item with raw text |
| `gtd.task.created` | InboxParsingHandler / TaskHandler | Created task (structured if from inbox parsing) |
| `gtd.task.updated` | TaskHandler | Updated task |
| `gtd.task.completed` | TaskHandler | Task marked complete |
| `gtd.decomposition.completed` | DecompositionHandler | Task decomposition completed with subtasks (Phase 2) |
| `gtd.project.created` | ProjectHandler | Created project |
| `gtd.project.updated` | ProjectHandler | Updated project |
| `gtd.error` | Any handler | Error during processing |
| `llm.inference.chain` | DecompositionHandler | Request LLM bot for multi-step chain inference (Phase 2) |

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

### Request Flow (Phase 2: Task Decomposition)

```
Complex task (from Phase 1 or manual creation)
  ↓
gtd.task.decompose
  ↓
DecompositionHandler
  ├── Validate payload and fetch task
  └── Publish llm.inference.chain with 3 steps:
      1. Break task into 3-5 subtasks
      2. Estimate effort for each subtask
      3. Identify dependencies between subtasks
        ↓ [async via NATS]
  LLM bot InferenceHandler
  ├── Execute 3-step chain
  ├── Collect step outputs
  └── Publish llm.chain.completed
        ↓
GTD Consumer
  ↓
DecompositionHandler.handle_chain_completed
  ├── Parse decomposition results
  ├── Store in DecompositionStore (with FSRS fields for Phase 3+)
  └── Publish gtd.decomposition.completed
```

### Key Modules

- **BotArmyGtd.NATS.Consumer** - Routes messages to handlers
- **BotArmyGtd.Handlers.InboxHandler** - Accepts raw text, requests parsing
- **BotArmyGtd.Handlers.InboxParsingHandler** - Creates tasks from parsed text (v0.2.0+)
- **BotArmyGtd.Handlers.TaskHandler** - Task creation/updates
- **BotArmyGtd.Handlers.ProjectHandler** - Project management
- **BotArmyGtd.Handlers.DecompositionHandler** - Multi-step task decomposition (Phase 2)
- **BotArmyGtd.{TaskStore, ProjectStore, InboxItemStore, DecompositionStore}** - GenServer-based persistence with DB fallback
- **BotArmyGtd.Graphs** / **GraphSource** - The four series this bot can draw from the task log
  (tasks opened, tasks closed, times worked, projects started) and the reads behind them. Pure
  bucketing; the reads are bounded by a window, never by a row count (§67)
- **BotArmyGtd.HouseholdDay** - The bot's one answer to "what day is it" — the host's own day, not
  UTC's (§65), and the day the graph buckets are counted from

## Graphs, and the day they are bucketed by

`gtd.graph.series` answers **every graph this bot can draw from the task log**, in one reply, and
draws none of them — the surface asks once and chooses which one to show:

```
gtd.graph.series   {}
  -> {"ok": true, "data": {"count": 4, "window_days": 84,
      "graphs": [{"id": "gtd.tasks.closed.week", "title": "Tasks closed", "unit": "tasks",
                   "kind": "bars", "note": "one bar is one week of tasks",
                   "points": [{"label": "Sep 28", "value": 3}, ...]}, ...]}}
```

* **four series**: tasks opened and tasks closed per week, *times a task was picked up* per week
  (one for each checkout row, which is not the same number as either), and projects started per
  **calendar month**. Each carries the labels of the buckets it is in, so a page prints the words it
  was handed and works out no dates of its own;
* **the series shape is deliberately identical to the fitness bot's**, field for field, so one card
  can parse both bots with one parser — the two logs are read side by side by the same page, and a
  week has to be the same week in both or "the last twelve weeks" means two different things on one
  screen;
* **the window is a window, not a page.** The reads are bounded by a date (`Graphs.window_start/1`,
  the Monday twelve weeks back) rather than by a row count, through a `GraphSource` seam so the
  handlers never touch the database themselves. The lower bound carries one day of slack, which the
  bucket function drops — the fleet has no IANA database, so a past instant cannot be converted to
  local time, and a day of slack costs nothing;
* **a task closed with no `completed_at` is left out rather than dated to `inserted_at`**: that would
  move a task into a week it did not happen in, which is the one thing a bar chart must not do;
* a read that fails is `read_failed`, never a menu of empty series.

`BotArmyGtd.HouseholdDay` is the same convention the fitness bot keeps (§65): every
`Date.utc_today/0` under `lib/` was replaced by `HouseholdDay.today()`, the host's own day, and the
boot log prints it beside its offset (`GTD bot day: 2026-10-16 (local offset -6h from UTC)`). A UTC
day stamped at 18:00 MDT would put her evening on tomorrow, and two conventions in one bot is a
defect rather than a nuance. The fleet carries no `tzdata` on purpose — an offset the runtime host
already knows is a lighter trade than a compile-time zone database.

## Phase Progress

### Phase 1: Inbox Parsing ✅ DONE (v0.2.0)
- Asynchronous text parsing via LLM bot
- JSON extraction schema: title, description, project, priority, due_date, tags
- Request correlation via inbox_item_id
- 8 comprehensive tests for InboxParsingHandler

### Phase 2: Task Decomposition 🔄 IN PROGRESS (v0.3.0)
- Multi-step breakdown of complex tasks via llm.inference.chain
- DecompositionStore with FSRS fields (baked in for Phase 3+ learning)
- Predicted vs actual effort tracking
- 9 comprehensive tests for DecompositionHandler
- NATS interface: gtd.task.decompose → llm.chain.completed → gtd.decomposition.completed

### Phase 3: Decomposition Review Queue 🔄 PLANNED (v0.4.0)
- User review of decomposition suggestions before task creation
- 1-5 star rating feedback collection
- Accuracy tracking by task type and complexity
- Learning system setup (metrics collection)

### Phase 4: Learning System 🔄 FUTURE (v1.0)
- Unified learning from decomposition feedback
- Personalized prompt adjustment based on accuracy history
- Cross-domain pattern detection

### Phase 5: Learning Bot Integration 🔄 FUTURE
- DecompositionCard scoring feeds Learning Bot
- Surface decomposition as learnable skill
- Tease model for decomposition improvement

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

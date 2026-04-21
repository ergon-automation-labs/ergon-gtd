# CLAUDE.md

Guidance for Claude Code when working with `bot_army_gtd`.

---

## Parent Framework

This repo follows the architecture and patterns defined in the parent governance framework:

**[→ See parent GOVERNANCE.md](/code/elixir_bots/GOVERNANCE.md)**

Key sections:
- **Core Principles** - Event-driven NATS, Ecto persistence, dependency injection
- **NATS Message Pattern** - Standard envelope structure for all messages
- **Handler Pattern** - Validation → processing → publishing pattern used by all handlers
- **Store Pattern** - GenServer-based data persistence (if applicable to this repo)
- **Testing Patterns** - Mox mocking for isolation, no DB access in tests

Repo-specific decisions are documented in `memory/DECISIONS.md` with parent references.

---

## Purpose

**bot_army_gtd** is the GTD (Getting Things Done) bot implementation.

Handles:
- Task inbox management
- Project organization
- Context-based task filtering
- State transitions and lifecycle management

---

## Claude Code Task Queue

Claude Code uses the GTD bot as its task execution queue via NATS (not direct DB access).

**Important:** Claude is treated as just another user in the system, not a special case.
The `user_id` field identifies Claude, and tasks are scoped to that user.

### How It Works

1. **Claude creates tasks** via `gtd.task.create` NATS subject with Claude's `user_id`
2. **GTD bot stores tasks** with the assigned `user_id` - no config needed
3. **Claude polls via NATS** by subscribing to `gtd.task.created` events filtered by its `user_id`
4. **Claude claims tasks** via `gtd.task.update` with `"status": "claimed"`
5. **Claude completes tasks** via `gtd.task.update` with result data in `"result"` field
6. **GTD publishes events** for each state change for audit trail

### Setting Claude's User ID

Claude uses a dedicated environment variable to identify itself:
```bash
BOT_ARMY_CLAUDE_USER_ID="00000000-0000-0000-0000-000000000002"
```

The GTD bot extracts `user_id` from NATS envelopes via `BotArmyCore.Tenant.extract_context/1`.
When Claude creates tasks, it should set `user_id` to the value of `BOT_ARMY_CLAUDE_USER_ID`.

**Note:** This is temporary until automated user onboarding is built (see "Future" section below).

### Future: Automated User Onboarding

A `bot_army_users` bot should be built to handle user registration via NATS:
- `users.user.create` - Register new user (returns user_id)
- `users.user.get` - Look up user by email/name
- Auto-generate UUIDs, store in DB, return to requester

This would allow Claude (or any system) to self-register as a user without manual config.

### Task State Flow

```
active → claimed → completed
```

### Task Result Format

```json
{
  "task_id": "...",
  "status": "completed",
  "result": {
    "output": "Result content",
    "success": true,
    "errors": [],
    "metrics": {}
  }
}
```

### Key Principle

**Always use NATS for communication** - the GTD bot is a service, not a shared library.
Direct database access breaks the isolation model and creates coupling.

---

## File Organization

```
.
├── lib/
│   ├── bot_army_gtd.ex                   # Main module
│   └── bot_army_gtd/
│       ├── application.ex                 # Application supervisor
│       ├── nats/
│       │   └── consumer.ex                # NATS message consumer
│       └── handlers/
│           ├── inbox_handler.ex
│           ├── task_handler.ex
│           └── project_handler.ex
├── test/
│   ├── test_helper.exs
│   └── bot_army_gtd/
│       ├── nats/
│       │   └── consumer_test.exs
│       └── handlers/
│           └── task_handler_test.exs
├── mix.exs
├── CLAUDE.md
├── README.md
└── memory/
    ├── MEMORY.md                # Session summaries
    ├── DECISIONS.md             # Architectural decisions with parent links
    └── PATTERNS.md              # Repo-specific code patterns
```

---

## Core Dependencies

- **bot_army_core** - NATS envelope decoding, schema validation
- **nats** - NATS client for message publishing/subscribing
- **jason** - JSON encoding/decoding
- **logger_json** - Structured JSON logging

The bot depends on schemas deployed by `bot_army_schemas_gtd` at `/etc/bot_army/schemas/gtd/`

---

## Development Workflow

### Setup

```bash
mix deps.get
mix test
```

### Key Modules

1. **BotArmyGtd.NATS.Consumer** - Subscribe to NATS subjects
2. **BotArmyGtd.Handlers.InboxHandler** - Process inbox messages
3. **BotArmyGtd.Handlers.TaskHandler** - Handle task operations
4. **BotArmyGtd.Handlers.ProjectHandler** - Manage projects
5. **BotArmyGtd.Handlers.DecompositionHandler** - Multi-step task decomposition (Phase 2)
6. **BotArmyGtd.DecompositionStore** - Store decomposition results with FSRS fields

### Task Status Flow

**General workflow:** `active → claimed → completed`

**Claude Code usage pattern:**
1. Claude creates task via `gtd.task.create` with `user_id="claude-<uuid>"`
2. GTD bot stores task and publishes `gtd.task.created` event
3. Claude polls events for its user_id
4. Claude claims task via `gtd.task.update` with `"status": "claimed"`
5. Claude completes task via `gtd.task.update` with `"result"` field
6. GTD bot publishes `gtd.task.updated` event with completion data

### Message Subjects

The bot listens to and publishes:
- `gtd.inbox.*` - Inbox operations
- `gtd.task.*` - Task operations
- `gtd.project.*` - Project operations

All messages follow the core envelope structure from `bot_army_core`.

---

## Testing

```bash
mix test                    # Run all tests
mix test --cover            # With coverage
mix credo                   # Linting
mix dialyzer                # Static analysis
```

---

## Deployment

This bot is deployed via Salt from `bot_army_infra`:

```bash
cd ../bot_army_infra
make deploy-bot BOT=gtd
```

Deployment happens after:
1. Core schemas deployed
2. bot_army_core library deployed

---

## Related Repositories

- `bot_army_schemas_gtd` - GTD message schemas
- `bot_army_core` - Core library and NATS decoder
- `bot_army_infra` - Deployment infrastructure

---

## Agent Workflow Pattern

**Effective use of Claude Code agents when developing this bot.**

This follows the polyrepo agent strategy documented in `bot_army_infra/CLAUDE.md`.

### When to Use Haiku Agents

- Exploring handler implementations and understanding existing patterns
- Reading test files to understand expected behavior
- Diagnostics: checking test failures, understanding error logs
- Code search: finding specific handlers or NATS subjects
- Verification: running tests, checking message flow

**Why**: Fast iteration loop, perfect for understanding how other bots are structured.

### When to Use Sonnet Agents

- Implementing new handlers or business logic
- Designing complex state transitions and workflows
- Multi-handler integrations and message routing
- Refactoring handlers for new requirements
- Performance optimizations

**Why**: Deep reasoning ensures handlers are correct, state management is sound, and error cases are handled.

### Example: Add New Task Operation

```
User: "Add task prioritization feature"
  ↓
1. Haiku (Explore): Read existing task_handler.ex, understand current operations
  ↓
2. Sonnet (Plan): Design new handler, identify state changes, schema changes needed
  ↓
3. Sonnet (Implement): Update handler, add tests, update NATS subjects
  ↓
4. Haiku (Verify): Run test suite, check message flow
```

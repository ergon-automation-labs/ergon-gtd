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

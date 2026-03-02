# CLAUDE.md

Guidance for Claude Code when working with `bot_army_gtd`.

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
└── README.md
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

### Key Modules to Implement

1. **BotArmyGtd.NATS.Consumer** - Subscribe to NATS subjects
2. **BotArmyGtd.Handlers.InboxHandler** - Process inbox messages
3. **BotArmyGtd.Handlers.TaskHandler** - Handle task operations
4. **BotArmyGtd.Handlers.ProjectHandler** - Manage projects

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

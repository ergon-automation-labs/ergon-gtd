# BotArmyGtd

GTD (Getting Things Done) bot implementation for the Bot Army ecosystem.

Manages task inbox, projects, and context-based organization.

## Building

```bash
mix deps.get
mix test
```

## Running

```bash
iex -S mix
```

## Architecture

- **NATS Consumer** - Listens for GTD-related messages
- **Event Handlers** - Processes task lifecycle events
- **Task Processor** - Manages task state and transitions

## Message Schemas

Schemas are defined in `bot_army_schemas_gtd` and deployed to `/etc/bot_army/schemas/gtd/`

## Dependencies

- `bot_army_core` - Core NATS decoder and envelope handling
- `nats` - NATS client library
- `jason` - JSON encoding/decoding
- `logger_json` - JSON logging

## Development

```bash
make setup    # Install dependencies
make test     # Run tests
make check    # Run all checks
```

## Related Repositories

- `bot_army_schemas_gtd` - GTD message schemas
- `bot_army_core` - Core library
- `bot_army_infra` - Deployment infrastructure

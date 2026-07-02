# GTD Leader Election & High Availability

## Overview

The GTD bot runs on two nodes (air and mini) with automatic leader election. This provides high availability: if the primary (air) becomes inaccessible, the standby (mini) automatically takes over without manual intervention.

**Primary**: Air GTD (always active, publishes heartbeats)  
**Standby**: Mini GTD (read-only, monitors heartbeats, promotes if needed)

## Architecture

```
┌─────────────────────────────────────────────┐
│         NATS Cluster (4222)                 │
├────────────────────────────────────────────┤
│ system.health.gtd (heartbeat every 30s)    │
│ gtd.task.* (work queue)                    │
│ gtd.project.* (project operations)         │
└────────┬──────────────────┬────────────────┘
         │                  │
    ┌────▼───────┐      ┌───▼──────────┐
    │  AIR GTD   │      │  MINI GTD    │
    │ PRIMARY    │      │  STANDBY     │
    │ (Leader)   │      │ (Read-only)  │
    │            │      │              │
    │ Publishes  │      │ Monitors     │
    │ heartbeat  │      │ heartbeat    │
    │ every 30s  │      │              │
    │ Can write  │      │ Promotes if  │
    │ to DB      │      │ no heartbeat │
    │            │      │ for 90s      │
    └────┬───────┘      └──────┬───────┘
         │                     │
         └─────────────────────┘
           PostgreSQL (shared)
```

## How It Works

### Normal Operation (Air Available)
1. **Air GTD** publishes health pulse every 30 seconds via `BotArmyRuntime.SynapseHealth.publish()`
2. **Mini GTD** receives heartbeat, confirms air is alive
3. **Mini GTD** remains in standby (read-only mode)
4. **All writes** go to air GTD
5. **Reads** can come from either node

### Failover (Air Unavailable)
1. **Mini GTD** stops receiving heartbeats from air
2. **After 90 seconds** with no heartbeat, mini enters leader election
3. **Mini GTD** promotes to leader (becomes writeable)
4. **All writes** now go to mini GTD
5. **Requests** are routed to mini GTD

### Recovery (Air Comes Back)
1. **Air GTD** resumes publishing heartbeats
2. **Mini GTD** detects heartbeat, demotes to standby
3. **Mini GTD** stops accepting writes
4. **Requests** resume routing to air GTD

## Configuration

### Per-Node Role

Set via environment variable (takes precedence) or config file.

**Air (Primary):**
```bash
GTD_NODE_ROLE=primary
```

**Mini (Standby):**
```bash
GTD_NODE_ROLE=standby
```

### Environment Variable (Runtime Override)

```bash
# Set before starting GTD bot
export GTD_NODE_ROLE=standby  # or primary
```

### Config Files

**Default behavior** (`config/config.exs`):
```elixir
config :bot_army_gtd, :node_role, :primary
```

**Mini-specific** (`config/mini.exs`):
```elixir
config :bot_army_gtd, :node_role, :standby
```

### Deployment Configuration

**Air (via Salt pillar):**
```yaml
services:
  bots:
    gtd:
      env:
        GTD_NODE_ROLE: primary
```

**Mini (via Salt pillar):**
```yaml
services:
  bots:
    gtd:
      env:
        GTD_NODE_ROLE: standby
```

## Write Gating

Only the **leader** (primary or promoted standby) can write to the database.

### TaskStore Write Operations
- `create/1` - Create new task
- `update/2` - Update task
- `complete/1` - Mark task complete

### ProjectStore Write Operations
- `create/1` - Create new project
- `update/2` - Update project

**Write Rejection:**
When a standby tries to write:
```
{:error, :not_leader}
```

**Log Message:**
```
[warning] TaskStore: Write rejected (not leader)
```

### Read Operations
Both primary and standby can read:
- `get/2` - Get single task/project
- `list/1` - List all tasks/projects
- All other read operations

## Monitoring

### Check Node Role

Via the `LeaderMonitor` API:
```elixir
# Check if current node is leader
BotArmyGtd.LeaderMonitor.is_leader?()
#=> true | false

# Get current role
BotArmyGtd.LeaderMonitor.get_role()
#=> :primary | :standby

# Get full status
BotArmyGtd.LeaderMonitor.get_status()
#=> %{
#     role: :standby,
#     is_leader: false,
#     last_heartbeat: 1719926401234
#   }
```

### Monitor Logs

**Primary (air) starting:**
```
[info] [LeaderMonitor] Starting with node_role=primary
```

**Standby (mini) starting:**
```
[info] [LeaderMonitor] Starting with node_role=standby
```

**Standby becoming leader (failover):**
```
[warning] [LeaderMonitor] No heartbeat for 90123ms (timeout: 90000ms), BECOMING LEADER
```

**Standby demoting (recovery):**
```
[info] [LeaderMonitor] Heartbeat from air detected, becoming standby
```

**Write rejection:**
```
[warning] TaskStore: Write rejected (not leader)
[warning] ProjectStore: Write rejected (not leader)
```

## Health Check

### Primary Health
Air GTD publishes health via `system.health.gtd` NATS subject every 30 seconds.

**Check primary status:**
```bash
nats request system.health.gtd '{}'
```

### Standby Health
Mini GTD can be queried via:
```bash
# Check if mini is in standby or leader mode
nats request gtd.health '{}'
```

## Troubleshooting

### Standby Not Promoting on Failover

**Symptoms:**
- Air GTD is down
- Mini GTD still in standby mode after 90+ seconds
- Writes to mini GTD return `:not_leader` error

**Debug:**
```elixir
# On mini, check:
BotArmyGtd.LeaderMonitor.get_status()

# Should show:
# %{
#   role: :standby,
#   is_leader: true,  # ← Should be true after 90s timeout
#   last_heartbeat: ...
# }
```

**Common Causes:**
1. **NATS connectivity issue** - Mini can't hear that air is down
   - Check NATS connection: `nats info`
   - Verify mini is connected to correct NATS server (4222)

2. **Heartbeat still present** - Air is still publishing (not actually down)
   - Check air GTD logs
   - Verify air NATS connection is working

3. **LeaderMonitor not running** - Check supervision tree
   - Verify LeaderMonitor started in application.ex
   - Check mix logs for errors during startup

### Primary Not Recovering Leadership

**Symptoms:**
- Air GTD comes back online
- Mini GTD still in leader mode
- Writes to air GTD are ignored

**Debug:**
```elixir
# On mini, check:
BotArmyGtd.LeaderMonitor.get_status()

# Should show is_leader: false after heartbeat resumes
```

**Common Causes:**
1. **Heartbeat not publishing** - Air GTD not sending heartbeats
   - Check air logs for PulsePublisher errors
   - Verify air can reach NATS

2. **NATS subscription lost** - Mini's heartbeat listener disconnected
   - Check mini logs for subscription errors
   - Verify mini NATS connection stability

### Both Nodes Think They're Leader

**Very rare** — indicates split-brain condition.

**Symptoms:**
- Both air and mini have `is_leader: true`
- Conflicting writes to database

**Recovery:**
1. Stop mini GTD immediately: `make restart-bot-mini BOT=gtd`
2. Verify air is primary and stable
3. Restart mini: it will detect air's heartbeat and revert to standby
4. Check logs for any NATS connectivity issues

### High Write Rejection Rate

**Symptoms:**
- Many logs: `[warning] TaskStore: Write rejected (not leader)`
- Mini GTD is leader but thinks it's not

**Cause:**
Timing issue where LeaderMonitor state is inconsistent with actual leadership.

**Fix:**
```bash
# Restart GTD on both nodes
make restart-bot-air BOT=gtd
make restart-bot-mini BOT=gtd
```

## Operations

### Manual Failover

To test failover or force mini to become leader:

```bash
# Stop air GTD
ssh air "systemctl stop bot_army_gtd" 

# Wait 90 seconds for mini to detect

# Verify mini is now leader
ssh mini "exs" # enter iex shell on mini GTD
> BotArmyGtd.LeaderMonitor.is_leader?()
true

# Verify you can write to mini
# (requests to bridge.task.* will be handled by mini)
```

### Manual Recovery

```bash
# Restart air GTD
ssh air "systemctl start bot_army_gtd"

# Wait for heartbeat (30 seconds)

# Verify mini returns to standby
ssh mini "exs"
> BotArmyGtd.LeaderMonitor.is_leader?()
false
```

### Monitoring Commands

```bash
# Check if air is alive (should be true)
curl http://air:5000/health

# Check if mini is alive (should be true even if standby)
curl http://mini:5000/health

# Check which node is leader
# (Can query any bridge.task.* endpoint; check logs to see who handled it)
nats request 4222 bridge.task.list '{}'
```

## Architecture Notes

### Heartbeat Mechanism

Uses existing **PulsePublisher** system:
- Published to: `system.health.gtd`
- Frequency: Every 30 seconds
- Includes: service name, status, uptime, sequence

### Timeout Design

- **Heartbeat timeout**: 90 seconds
- **Health check interval**: 10 seconds
- **NATS queue group**: `gtd-leader-monitor`

Why 90 seconds?
- Accounts for NATS network jitter (30s per heartbeat × 3 = 90s)
- Prevents false positives from brief connectivity issues
- Gives air time to recover if it's temporarily unavailable

### Database Consistency

Both nodes share the same PostgreSQL database:
- **Writes** are gated per node (only leader writes)
- **Reads** can come from either node
- **Transactions** are Ecto-level; no special consensus logic needed

On failover:
- Standby reads any writes that air made before becoming unavailable
- Standby can immediately start writing
- No data loss occurs (writes made by air are persisted in DB)

## Related Files

- **LeaderMonitor**: `lib/bot_army_gtd/leader_monitor.ex`
- **TaskStore gating**: `lib/bot_army_gtd/task_store.ex` (create, update, complete)
- **ProjectStore gating**: `lib/bot_army_gtd/project_store.ex` (create, update)
- **Config**: `config/config.exs`, `config/mini.exs`
- **PulsePublisher**: `lib/bot_army_gtd/pulse_publisher.ex`
- **Deployment**: `pillar/air.sls`, `pillar/mini.sls`

## Testing

### Unit Tests

```bash
# Test LeaderMonitor logic
cd /Users/abby/code/bots/bot_army_gtd
mix test --only leader

# Test write gating
mix test --only stores
```

### Manual Integration Test

```bash
# Terminal 1: Start air GTD
NATS_SERVERS=localhost:4223 MIX_ENV=dev mix phx.server

# Terminal 2: Start mini GTD
GTD_NODE_ROLE=standby NATS_SERVERS=localhost:4223 MIX_ENV=dev mix phx.server

# Terminal 3: Test
nats request localhost:4223 bridge.task.create '{"title":"test"}'

# Verify air handles it (check air's logs)
# Then kill air GTD
# Wait 90 seconds
# Verify mini GTD now handles subsequent requests
```

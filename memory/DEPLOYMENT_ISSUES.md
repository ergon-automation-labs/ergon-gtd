# Deployment Issues - Elixir Release Cookie Mismatch

**Date:** 2026-04-22

## Problem

v0.6.2 and later versions of the GTD bot failed to start properly. Only the HealthResponder process started; the full supervision tree (NATS.Consumer, TaskStore, etc.) did not initialize.

## Root Cause

### Environment Variable Mismatch

The Elixir release wrapper scripts use `RELEASE_COOKIE` and `RELEASE_NODE` environment variables, but the Salt-generated env files were only setting `ERLANG_COOKIE` and `ERLANG_NODE`.

The release script defaults to reading from `$RELEASE_ROOT/releases/COOKIE` when `RELEASE_COOKIE` is not set, but this file contained a different cookie value than what the wrapper set via `ERLANG_COOKIE`.

**Process behavior:**
- Wrapper sets: `ERLANG_COOKIE=bot_army_secret_cookie`
- Release script uses: `RELEASE_COOKIE` (defaults to file: `4CJVBWI2DBRU2ZGYZAOC3TOCSKZXXWZGOHRKBEEWFIGHFMTS5DTA====`)
- Cookie mismatch prevents proper Erlang distribution → application doesn't start

### Wrapper Script Issue

The wrapper script at `/opt/bot_army/wrappers/bot_wrapper.sh` reads from `/etc/bot_army/gtd_bot.env` and exports variables using `eval "export $key='$value'"`. While this works for `ERLANG_*` vars, Elixir releases expect `RELEASE_*` vars.

## Solution

### 1. Salt State Configuration

Updated all bot Salt states (`salt/bots/*.sls`) to export both ERLANG_* and RELEASE_* variables:

```yaml
ERLANG_NODE={{ bot_erlang_node }}@{{ grains['fqdn'] }}
ERLANG_COOKIE={{ bot_erlang_cookie }}
# Elixir releases use RELEASE_* instead of ERLANG_*
RELEASE_NODE={{ bot_erlang_node }}@{{ grains['fqdn'] }}
RELEASE_COOKIE={{ bot_erlang_cookie }}
```

**Affected files:**
- advocacy_bot.sls
- bot_army_rss_polling.sls
- chore_bot.sls
- claude_bridge_bot.sls
- context_broker_bot.sls
- database_backups_bot.sls
- discord_bot.sls
- email_triage_bot.sls
- fitness_bot.sls
- gtd_bot.sls
- identity_bot.sls
- job_applications_bot.sls
- learning_bot.sls
- llm_bot.sls
- notification_router_bot.sls
- synapse_bot.sls
- terrain_bot.sls

### 2. Process Verification

All bot processes run with PPID=1 (managed by launchd). GTD bot is no different in this regard - all bots are controlled directly by launchd, not by the wrapper script.

## Verification Steps

1. Re-run Salt state: `salt 'air' state.apply bots.gtd_bot`
2. Verify env file contains RELEASE_* vars: `cat /etc/bot_army/gtd_bot.env`
3. Restart bot: `launchctl unload /Library/LaunchDaemons/com.botarmy.gtd_bot.plist && launchctl load -w /Library/LaunchDaemons/com.botarmy.gtd_bot.plist`
4. Check process: `ps aux | grep beam | grep gtd`
5. Verify log: `tail -50 /var/log/bot_army/gtd_bot.log`

## Related Issues

- Previous deployment issues with Ecto migration syntax errors (v0.6.0, v0.6.3)
- Configuration mismatch between compile-time and runtime (`auto_start_services`)
- NATS header nil access issue (`Map.get(msg, :headers, [])`)

## Prevention

**Rule:** All bot Salt states must include both ERLANG_* and RELEASE_* environment variable pairs to ensure compatibility with both the wrapper script and Elixir release scripts.

**Checklist for new bot deployments:**
- [ ] Env file includes `RELEASE_NODE` and `RELEASE_COOKIE`
- [ ] Cookie value matches across all references
- [ ] Wrapper script successfully sources all env vars
- [ ] Process starts with correct cookie (check logs for NATS connection)

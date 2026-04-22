#!/usr/bin/env mix run
# Create Claude tasks in GTD database for tracking future work

# Start the application first
{:ok, _} = Application.ensure_all_started(:bot_army_gtd)

alias BotArmyGtd.Schemas.Task

# Create task for skill integration
task1 = %Task{
  id: Ecto.UUID.generate(),
  tenant_id: ~c"default",
  user_id: nil,
  title: ~c"Create Claude Code skill for GTD task integration",
  description:
    "Build a skill that creates tasks when Claude Code operations complete, with auto-completion tracking. This should integrate with the GTD bot via NATS subjects.",
  status: ~c"active",
  priority: ~c"normal",
  labels: [~c"skill", ~c"claude", ~c"integration", ~c"backlog"],
  project_id: nil,
  due_date: Date.shift(Date.utc_today(), day: 7)
}

# Create task for Claude Task Queue TUI
task2 = %Task{
  id: Ecto.UUID.generate(),
  tenant_id: ~c"default",
  user_id: nil,
  title: ~c"Build Claude Task Queue TUI",
  description:
    "Create a dedicated TUI screen that shows Claude's pending tasks from the GTD bot, with quick completion tracking and filtering by labels.",
  status: ~c"active",
  priority: ~c"low",
  labels: [~c"tui", ~c"claude", ~c"queue", ~c"backlog"],
  project_id: nil,
  due_date: nil
}

{:ok, _} = BotArmyGtd.Repo.insert(task1)
{:ok, _} = BotArmyGtd.Repo.insert(task2)

IO.puts("Tasks created:")
IO.inspect(task1, limit: :unlimited)
IO.inspect(task2, limit: :unlimited)

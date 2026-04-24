# GTD Bot NATS API Reference

Complete API for managing tasks and projects via NATS messaging.

## Base Configuration

- **Tenant ID**: `00000000-0000-0000-0000-000000000001` (default)
- **User ID**: `00000000-0000-0000-0000-000000000002` (default)
- **NATS Server** (dev): `nats://localhost:4223`
- **NATS Server** (prod): `nats://localhost:4222`

## Projects

### Create Project

**Subject**: `gtd.project.create`  
**Pattern**: Request/Reply (use `nats pub` - fire and forget, no responder)

```json
{
  "event": "gtd.project.create",
  "event_id": "<uuid>",
  "timestamp": "<iso8601>",
  "source": "bot_name",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "user_id": "00000000-0000-0000-0000-000000000002",
  "payload": {
    "name": "Project Name",
    "description": "Optional description",
    "labels": ["optional", "labels"]
  }
}
```

**Response Event**: `gtd.project.created` (published to `events.gtd.project.created`)

### Update Project

**Subject**: `gtd.project.update`  
**Pattern**: Request/Reply

```json
{
  "event": "gtd.project.update",
  "event_id": "<uuid>",
  "timestamp": "<iso8601>",
  "source": "bot_name",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "user_id": "00000000-0000-0000-0000-000000000002",
  "payload": {
    "project_id": "<project_id>",
    "name": "Updated Name",
    "status": "active|archived|completed",
    "labels": ["updated", "labels"]
  }
}
```

**Response Event**: `gtd.project.updated` (published to `events.gtd.project.updated`)

### List Projects

**Subject**: `gtd.project.list`  
**Pattern**: Request/Reply

```json
{
  "tenant_id": "00000000-0000-0000-0000-000000000001"
}
```

**Response**: Array of projects with id, name, description, status, labels, created_at, updated_at

## Tasks

### Create Task

**Subject**: `gtd.task.create`  
**Pattern**: Request/Reply

```json
{
  "event": "gtd.task.create",
  "event_id": "<uuid>",
  "timestamp": "<iso8601>",
  "source": "bot_name",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "user_id": "00000000-0000-0000-0000-000000000002",
  "payload": {
    "title": "Task Title",
    "description": "Optional description",
    "context": "inbox|next|someday|reference|waiting",
    "priority": "low|normal|high|urgent",
    "project_id": "<optional_project_id>",
    "labels": ["optional", "labels"],
    "due_date": "2026-04-25"
  }
}
```

**Response Event**: `gtd.task.created` (published to `events.gtd.task.created`)

### Update Task

**Subject**: `gtd.task.update`  
**Pattern**: Request/Reply

```json
{
  "event": "gtd.task.update",
  "event_id": "<uuid>",
  "timestamp": "<iso8601>",
  "source": "bot_name",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "user_id": "00000000-0000-0000-0000-000000000002",
  "payload": {
    "task_id": "<task_id>",
    "title": "Updated Title",
    "status": "active|claimed|completed",
    "priority": "low|normal|high|urgent",
    "project_id": "<new_project_id>",
    "result": {
      "success": true,
      "output": "Execution result",
      "errors": [],
      "duration_ms": 1234
    },
    "labels": ["updated", "labels"]
  }
}
```

**Response Event**: `gtd.task.updated` (published to `events.gtd.task.updated`)

### Complete Task

**Subject**: `gtd.task.complete`  
**Pattern**: Request/Reply

```json
{
  "event": "gtd.task.complete",
  "event_id": "<uuid>",
  "timestamp": "<iso8601>",
  "source": "bot_name",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "user_id": "00000000-0000-0000-0000-000000000002",
  "payload": {
    "task_id": "<task_id>"
  }
}
```

**Response Event**: `gtd.task.completed` (published to `events.gtd.task.completed`)

### List Tasks

**Subject**: `gtd.task.list`  
**Pattern**: Request/Reply

```json
{
  "tenant_id": "00000000-0000-0000-0000-000000000001"
}
```

**Response**: Array of tasks with id, title, status, priority, context, project_id, result, labels, created_at, completed_at

## Error Handling

All operations that fail publish a `gtd.error` event:

```json
{
  "event": "gtd.error",
  "event_id": "<uuid>",
  "timestamp": "<iso8601>",
  "source": "bot_army_gtd",
  "source_node": "air",
  "triggered_by": "gtd.bot",
  "schema_version": "1.0",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "user_id": "00000000-0000-0000-0000-000000000002",
  "payload": {
    "error": "Human readable message",
    "reason": "Machine readable reason",
    "triggered_by_event_id": "<original_event_id>"
  }
}
```

## Status Values

### Task Status
- `active` - Normal, available task
- `claimed` - Task is being worked on
- `completed` - Task finished

### Project Status
- `active` - Normal, active project
- `archived` - Project is archived
- `completed` - Project finished

## Claude Bridge Integration

When Claude Bridge creates tasks for Claude Code to work on:

1. Create task via `gtd.task.create` with Claude's `user_id`
2. Claude polls `gtd.task.list` for its assigned user_id
3. Claude claims task: `gtd.task.update` with `status: "claimed"`
4. Claude executes work and sets `result` field
5. Claude completes task: `gtd.task.complete`

**Key Fields for Claude:**
- `status: "claimed"` - Task is in progress by Claude
- `result` - Stores execution output, success flag, errors, duration
- `project_id` - Groups related Claude operations

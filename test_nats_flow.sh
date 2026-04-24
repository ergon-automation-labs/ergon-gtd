#!/bin/bash
# Manual NATS testing script for GTD project/task operations
# Tests the complete flow: create project → create task in project → update task → complete task

set -e

NATS_SERVER="nats://localhost:4223"  # dev port
TENANT_ID="00000000-0000-0000-0000-000000000001"
USER_ID="00000000-0000-0000-0000-000000000002"

echo "=== GTD Project/Task NATS Flow Test ==="
echo "NATS Server: $NATS_SERVER"
echo "Tenant: $TENANT_ID"
echo "User: $USER_ID"
echo

# 1. Create a project
echo "1. Creating project..."
PROJECT_RESPONSE=$(nats request --server "$NATS_SERVER" gtd.project.create '{
  "event": "gtd.project.create",
  "event_id": "'$(uuidgen)'",
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test_script",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "'$TENANT_ID'",
  "user_id": "'$USER_ID'",
  "payload": {
    "name": "Test Project - '$(date +%s)'",
    "description": "Created via test script",
    "labels": ["test", "nats"]
  }
}' --timeout 5s 2>&1)

echo "$PROJECT_RESPONSE" | tail -20
echo

# 2. List projects to verify creation
echo "2. Listing projects..."
PROJECTS=$(nats request --server "$NATS_SERVER" gtd.project.list '{
  "tenant_id": "'$TENANT_ID'"
}' --timeout 5s 2>&1)

echo "$PROJECTS" | tail -30
PROJECT_ID=$(echo "$PROJECTS" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Found project ID: $PROJECT_ID"
echo

# 3. Create a task associated with the project
echo "3. Creating task associated with project..."
TASK_RESPONSE=$(nats request --server "$NATS_SERVER" gtd.task.create '{
  "event": "gtd.task.create",
  "event_id": "'$(uuidgen)'",
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test_script",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "'$TENANT_ID'",
  "user_id": "'$USER_ID'",
  "payload": {
    "title": "Test Task - '$(date +%s)'",
    "description": "Task in project",
    "project_id": "'$PROJECT_ID'",
    "context": "inbox",
    "priority": "high",
    "labels": ["test"]
  }
}' --timeout 5s 2>&1)

echo "$TASK_RESPONSE" | tail -20
TASK_ID=$(echo "$TASK_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Found task ID: $TASK_ID"
echo

# 4. List tasks to verify creation
echo "4. Listing tasks..."
TASKS=$(nats request --server "$NATS_SERVER" gtd.task.list '{
  "tenant_id": "'$TENANT_ID'"
}' --timeout 5s 2>&1)

echo "$TASKS" | tail -30
echo

# 5. Update task (move to claimed status)
echo "5. Updating task status to 'claimed'..."
UPDATE_RESPONSE=$(nats request --server "$NATS_SERVER" gtd.task.update '{
  "event": "gtd.task.update",
  "event_id": "'$(uuidgen)'",
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test_script",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "'$TENANT_ID'",
  "user_id": "'$USER_ID'",
  "payload": {
    "task_id": "'$TASK_ID'",
    "status": "claimed"
  }
}' --timeout 5s 2>&1)

echo "$UPDATE_RESPONSE" | tail -20
echo

# 6. Update task with result (simulating task completion)
echo "6. Setting task result..."
RESULT_RESPONSE=$(nats request --server "$NATS_SERVER" gtd.task.update '{
  "event": "gtd.task.update",
  "event_id": "'$(uuidgen)'",
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test_script",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "'$TENANT_ID'",
  "user_id": "'$USER_ID'",
  "payload": {
    "task_id": "'$TASK_ID'",
    "result": {
      "success": true,
      "output": "Task completed successfully",
      "duration_ms": 1234
    }
  }
}' --timeout 5s 2>&1)

echo "$RESULT_RESPONSE" | tail -20
echo

# 7. Complete the task
echo "7. Completing task..."
COMPLETE_RESPONSE=$(nats request --server "$NATS_SERVER" gtd.task.complete '{
  "event": "gtd.task.complete",
  "event_id": "'$(uuidgen)'",
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test_script",
  "source_node": "air",
  "triggered_by": "user",
  "schema_version": "1.0",
  "tenant_id": "'$TENANT_ID'",
  "user_id": "'$USER_ID'",
  "payload": {
    "task_id": "'$TASK_ID'"
  }
}' --timeout 5s 2>&1)

echo "$COMPLETE_RESPONSE" | tail -20
echo

# 8. List final state
echo "8. Final task state:"
FINAL_TASKS=$(nats request --server "$NATS_SERVER" gtd.task.list '{
  "tenant_id": "'$TENANT_ID'"
}' --timeout 5s 2>&1)

echo "$FINAL_TASKS" | tail -30
echo

echo "=== Test Complete ==="

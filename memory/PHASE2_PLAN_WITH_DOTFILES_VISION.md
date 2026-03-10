# Phase 2 Plan: Task Decomposition with Dotfiles Vision

**Scope**: Implement llm.inference.chain workflow for complex task breakdown
**Timeline**: v0.3.0
**Philosophy**: Build Phase 2 with extensibility for future dotfiles patterns (review, learning, caching)

---

## Phase 2: Task Decomposition Overview

### What Problem Are We Solving?

Users often capture complex tasks as single inbox items:
- "Implement user authentication system"
- "Plan team offsite"
- "Launch product"

Without decomposition, these stay as single large tasks. With decomposition, they become task hierarchies with effort estimates and dependencies.

### The Flow

```
User adds complex task
  ↓
InboxHandler → InboxParsingHandler (Phase 1)
  ↓
Creates "parent" task
  ↓
[NEW] DecompositionHandler → llm.inference.chain (Phase 2)
  ↓
Step 1: "Break task into 3-5 subtasks"
Step 2: "Estimate effort for each subtask"
Step 3: "Identify dependencies between subtasks"
  ↓
Publishes decomposition results
  ↓
[FUTURE] TaskReviewQueue (Phase 3 from dotfiles) - Review before creating
  ↓
Creates subtasks in TaskStore with relationships
  ↓
Publishes gtd.task.created for each subtask
```

---

## Architecture: Decomposition-First with Dotfiles Extensibility

### Core Decomposition (Phase 2 Focus)

**New Module: DecompositionHandler**
- Listens for: `gtd.task.decompose` events (or auto-trigger on complex tasks)
- Calls: `llm.inference.chain` (3 steps as shown above)
- Publishes:
  - `llm.inference.chain` request to LLM bot
  - Receives: `llm.chain.completed` with all step outputs
  - Creates: `gtd.decomposition.completed` event with subtask list

**Key Design Decision**: Store decomposition results before creating subtasks
```elixir
DecompositionCache (new table):
  id: UUID
  parent_task_id: UUID
  decomposition_steps: [
    %{"prompt" => "...", "output" => "3-5 subtasks: ..."},
    %{"prompt" => "...", "output" => "Effort estimates: ..."},
    %{"prompt" => "...", "output" => "Dependencies: ..."}
  ]
  subtasks_created: false  # Phase 3: review before setting to true
  created_at: timestamp
  completed_at: timestamp
```

**Why This Design?**
- ✅ Supports future review queue (don't create tasks immediately)
- ✅ Enables caching (don't decompose same task twice)
- ✅ Tracks decomposition history for learning
- ✅ Allows async review without blocking

### Extensibility Points (Baked In)

#### Point 1: Decomposition Review Queue (Phase 3)
```elixir
# Phase 2: After llm.chain.completed arrives
DecompositionHandler.process_completed(decomposition_id)
  ├─ Option A (v0.3.0): Auto-create subtasks
  └─ Option B (v0.4.0): Create suggestion in review queue
      - Show user: "3 subtasks with dependencies"
      - User approves → creates subtasks
      - User rejects → discards
      - User edits → stores feedback for learning
```

**Implementation**: Just add a config flag:
```elixir
decomposition_mode = Application.get_env(:bot_army_gtd, :decomposition_mode, :auto_create)
# :auto_create = Phase 2 behavior
# :review_queue = Phase 3+ behavior
```

#### Point 2: Decomposition Accuracy Tracking (Phase 3+)
```elixir
DecompositionMetrics (new table):
  parent_task_id: UUID
  decomposition_id: UUID

  # Predicted vs actual
  predicted_subtask_count: 3
  actual_subtask_count: 3

  # User feedback (1-5 stars)
  quality_rating: 4
  feedback_text: "Missing one step"

  # Learning signals
  user_accepted: true
  user_edited_subtasks: false
  user_marked_complete: true
  completion_time_hours: 4.5  # vs predicted

  created_at: timestamp
```

**Why Design This Way?**
- Phase 2: Just collect metrics, no learning yet
- Phase 3: Use metrics to improve decomposition prompts
- Phase 4: Personalize by task type/user

#### Point 3: Decomposition Caching (Low Priority, but Prepare For It)
```elixir
DecompositionCache.get_or_decompose(parent_task_id, task_description)
  ├─ Check cache: (task_description_hash, decomposition_hash)
  ├─ If found: return cached decomposition
  └─ If not: call llm.inference.chain, store result

# Cache expires: 30 days (task context changes, decomposition becomes stale)
```

---

## Phase 2 Implementation Details

### 1. New Handler: DecompositionHandler

**File**: `lib/bot_army_gtd/handlers/decomposition_handler.ex`

```elixir
defmodule BotArmyGtd.Handlers.DecompositionHandler do
  @moduledoc """
  Handles task decomposition via multi-step LLM chain.

  Breaks complex tasks into subtasks with effort estimates and dependencies.
  Uses llm.inference.chain for 3-step pipeline.
  """

  def handle_decompose(message) do
    # Validate payload
    # Call llm.inference.chain
    # Store intermediate results
    # Publish gtd.decomposition.completed
  end

  def handle_chain_completed(message) do
    # Receive llm.chain.completed
    # Parse step outputs (subtasks, effort, dependencies)
    # Store in DecompositionCache
    # [Phase 3: Or publish to review queue]
    # Create subtasks in TaskStore
  end
end
```

### 2. NATS Message Interface

**Incoming**:
- `gtd.task.decompose` - Request task decomposition
- `llm.chain.completed` - Receive multi-step results

**Outgoing**:
- `llm.inference.chain` - Send decomposition steps to LLM
- `gtd.decomposition.completed` - Publish results
- `gtd.task.created` - Create subtasks (1 event per subtask)
- `gtd.error` - On failure

### 3. Database Schema Changes

**New Table: decompositions**
```sql
CREATE TABLE decompositions (
  id UUID PRIMARY KEY,
  parent_task_id UUID NOT NULL REFERENCES tasks(id),

  -- Steps and outputs
  step_outputs JSONB NOT NULL,  -- Array of {prompt, output}
  subtask_list JSONB,           -- Parsed subtasks
  effort_estimates JSONB,       -- Effort per subtask
  dependencies JSONB,           -- Subtask relationships

  -- Status
  status STRING NOT NULL DEFAULT 'in_progress', -- in_progress, completed, failed, reviewed

  -- Extensibility (for Phase 3+)
  review_queue_id UUID,         -- Link to review queue (Phase 3)
  user_rating INT,              -- 1-5 stars (Phase 3)
  user_feedback TEXT,           -- "Missing..." (Phase 3)

  -- Metadata
  created_at TIMESTAMP,
  completed_at TIMESTAMP
);

CREATE INDEX idx_decompositions_parent_task ON decompositions(parent_task_id);
CREATE INDEX idx_decompositions_status ON decompositions(status);
```

### 4. Consumer Updates

```elixir
# Add to route_message/1:
"gtd.task.decompose" -> DecompositionHandler.handle_decompose(message)
"llm.chain.completed" -> DecompositionHandler.handle_chain_completed(message)
```

### 5. Tests (8-10 comprehensive tests)

- Happy path: 3-step chain, creates subtasks
- Missing steps: LLM returns incomplete output
- Dependency parsing: Complex task with prerequisites
- Error cases: LLM timeout, malformed output
- Extensibility: Verify structure supports Phase 3 review queue
- Metrics: Verify data captured for learning

### 6. TaskStore Extension

Current TaskStore has task creation. Enhance with:
```elixir
def create_with_relationships(task_params, parent_task_id, depends_on_ids) do
  # Create task
  # Store parent_task_id relationship
  # Store dependency_ids (for task ordering)
  # Return created task with relationships
end
```

---

## Dotfiles Patterns: Which Ones Apply Now vs Later?

### ✅ Bake In Now (Design-Level)

1. **Decomposition Caching Structure**
   - Add `decomposition_cache` field to schema
   - Don't populate it yet, but infrastructure is there
   - When Phase 3 adds learning: just activate cache lookup

2. **Metrics Collection**
   - Store decomposition steps, outputs, timing
   - Track user feedback (rating, edits, completion time)
   - No processing yet, just capture data
   - Phase 3: Use data for accuracy tracking

3. **Review Queue Hooks**
   - Add config flag: `decomposition_mode: :auto_create | :review_queue`
   - Phase 2: Always `:auto_create`
   - Phase 3: Can flip to `:review_queue` without changing code

4. **Structured Result Storage**
   - Store `subtask_list`, `effort_estimates`, `dependencies` as separate JSONB fields
   - Enables Phase 3 review queue to display structured suggestions
   - Enables Phase 4 learning system to track accuracy per field

### ⏳ Save for Phase 3+ (But Anticipate)

1. **Human-in-the-Loop Review Queue**
   - Wait until Phase 3
   - But Phase 2 schema prepares for it

2. **Learning System**
   - Phase 4 feature
   - Metrics captured in Phase 2 enable it

3. **Vector Embeddings**
   - Phase 4+ (nice-to-have)
   - Not needed for decomposition

4. **Cross-Domain Intelligence**
   - Phase 4+ (after parsing + decomposition systems mature)

---

## Phase 2 Success Criteria

### Code Quality
- [ ] 10+ comprehensive tests passing
- [ ] Compile with `--warnings-as-errors`
- [ ] Credo passes all lints
- [ ] No database access in unit tests

### Functionality
- [ ] Accepts `gtd.task.decompose` events
- [ ] Publishes `llm.inference.chain` to LLM bot
- [ ] Receives `llm.chain.completed` responses
- [ ] Parses multi-step outputs correctly
- [ ] Creates subtask relationships
- [ ] Publishes `gtd.task.created` for each subtask

### Extensibility
- [ ] Decomposition schema supports review queue (Phase 3)
- [ ] Metrics collected for learning system (Phase 3+)
- [ ] Config flag allows mode switching (auto_create → review_queue)
- [ ] Structured result storage (not flattened)

### Documentation
- [ ] CLAUDE.md updated with Phase 2 modules
- [ ] README.md updated with Phase 2 message types and flow
- [ ] DECISIONS.md: Phase 2 decision + rationale
- [ ] DOTFILES_GTD_LEARNINGS.md: Which patterns implemented/anticipated

### Traffic Generation
- [ ] Every complex inbox task → llm.inference.chain (3 steps)
- [ ] Estimated: 25-50 decomposition calls/week (5% of tasks are complex)
- [ ] Total LLM traffic: 250 (parsing) + 75 (decomposition) = 325 calls/week

---

## Architecture Diagram: Phases 1-3 Evolution

```
PHASE 1 (v0.2.0): Inbox Parsing
┌─────────────────────────────────┐
│  User inbox text                │
│  ↓                              │
│  InboxHandler → parse request   │
│  ↓ [async]                      │
│  InboxParsingHandler            │
│  ↓                              │
│  Task created (auto)            │
└─────────────────────────────────┘

PHASE 2 (v0.3.0): Decomposition
┌─────────────────────────────────┐
│  Simple task [auto-create]      │ ← No decomposition
│                                 │
│  Complex task                   │
│  ↓                              │
│  DecompositionHandler           │
│  ↓ [async, 3 steps]             │
│  Subtasks created (auto)        │
│                                 │
│  [Metrics collected]            │
└─────────────────────────────────┘

PHASE 3 (v0.4.0): Human Review
┌─────────────────────────────────┐
│  Decomposition results          │
│  ↓                              │
│  [NEW] ReviewQueue              │
│  ↓ (human approves/edits)       │
│  Subtasks created (approved)    │
│                                 │
│  [Rating feedback collected]    │
│  [Metrics processed for learning]
└─────────────────────────────────┘

PHASE 4 (v1.0): Learning System
┌─────────────────────────────────┐
│  [NEW] UnifiedLearningSystem    │
│  ↓ (processes Phase 2-3 metrics)│
│  Personalized decomposition     │
│  ↓ (adjusted prompts per user)  │
│  Better accuracy over time      │
└─────────────────────────────────┘
```

---

## Quick Reference: What to Implement vs Anticipate

| Feature | Phase 2 | Phase 3 | Phase 4 |
|---------|---------|---------|---------|
| **Decomposition execution** | ✅ Implement | - | - |
| **Multi-step chain** | ✅ Implement | - | - |
| **Subtask creation** | ✅ Implement | - | - |
| **Metrics collection** | ✅ Implement | - | - |
| **Caching structure** | 🏗️ Bake in | ⏳ Activate | - |
| **Review queue hooks** | 🏗️ Config flag | ✅ Implement | - |
| **Rating feedback** | 🏗️ Schema field | ✅ Collect | - |
| **Learning system** | - | - | ✅ Implement |
| **Vector embeddings** | - | - | ⏳ Consider |

---

## Implementation Order (Detailed)

### Step 1: Update Consumer (5 min)
- Add routing for `gtd.task.decompose` and `llm.chain.completed`

### Step 2: Database Migration (10 min)
- Create decompositions table with all Phase 3/4 fields

### Step 3: DecompositionHandler (1 hour)
- handle_decompose: Validate, build chain, publish llm.inference.chain
- handle_chain_completed: Parse results, create subtasks
- include metrics collection

### Step 4: TaskStore Enhancement (20 min)
- Add relationship creation support

### Step 5: Tests (1.5 hours)
- 8-10 comprehensive tests
- Test extensibility hooks

### Step 6: Documentation (30 min)
- Update CLAUDE.md, README.md, DECISIONS.md
- Add section to DOTFILES_GTD_LEARNINGS.md

**Total**: ~3.5 hours implementation

---

## Risk Mitigation: Potential Issues

### Issue 1: LLM Chain Timeout
- **Risk**: Step 2 or 3 takes too long
- **Mitigation**: Timeout per step (10 sec), skip failed step, publish partial results

### Issue 2: Malformed LLM Output
- **Risk**: LLM doesn't structure output as expected
- **Mitigation**: Use JsonExtractor (Phase 1) to extract JSON from step outputs

### Issue 3: Circular Dependencies
- **Risk**: LLM suggests task A depends on task B, B depends on A
- **Mitigation**: Detect cycles, flag in error, don't create relationships

### Issue 4: Subtask Explosion
- **Risk**: LLM breaks 1 task into 50 subtasks
- **Mitigation**: Cap at 10 subtasks, log warning, ask user

---

## Dotfiles Learnings Applied

### ✅ Already Using (Phase 1-2)
1. Freeform → structured pipeline (Phase 1)
2. Async NATS processing (Phase 1-2)
3. AI-powered organization (Phase 1-2)

### 🏗️ Baking In (Anticipate Phase 3-4)
1. Human-in-the-loop review (config flag)
2. Metrics for learning system (field-by-field accuracy)
3. Caching to prevent reprocessing (schema support)
4. Confidence scores (can add to LLM response)

### ⏳ Will Implement Later
1. Full review queue UI (Phase 3)
2. Learning system (Phase 4)
3. Semantic search (Phase 4+)
4. Cross-domain intelligence (Phase 4+)

---

## Stretch Goal (If Time Permits)

If Phase 2 implementation finishes early, consider:
1. Add confidence scores to llm.inference.chain response
2. Add optional user_id to decomposition for per-user metrics
3. Add complexity score detection (when to auto-trigger decomposition)

But don't block Phase 2 on these - they can wait for Phase 3.

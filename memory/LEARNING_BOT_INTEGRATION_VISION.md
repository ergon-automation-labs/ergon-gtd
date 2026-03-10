# Learning Bot × GTD Bot Integration Vision

## Key Context from North Stars

### Learning Bot (Spaced Repetition Engine)
- **Algorithm**: FSRS (Free Spaced Repetition Scheduler), not SM-2
- **Grading**: 4-scale (again/hard/good/easy), plus binary "do you know it?"
- **Surfaces**: G2 glasses, terminal, smart mirror, API
- **Core**: Ambient learning via "tease model" (push cards at right moment)
- **Dependencies**: Context Broker (for surface-aware delivery), LLM Proxy (for grading)

### GTD Bot (Task Management Hub)
- **Central Inbox**: `gtd.inbox.add` is the unified interface ALL bots use
- **Learning Bot Status**: Listed as a dependent (Learning Bot publishes to GTD inbox)
- **Clarification**: Two-tier (rule engine first, LLM fallback for ambiguous items)
- **Task States**: next_action → waiting_for → someday_maybe → reference/done/deleted
- **Surfaces**: G2 (overdue alerts), phone (reminders), mirror (ambient list), desktop (LiveView), terminal

### Critical Integration Point

From GTD North Star (line 19-20):
> "The Learning Bot...all depend on GTD Bot as their task handoff point"

This means Learning Bot fires `gtd.inbox.add` to create "learning tasks" in GTD.

---

## Phase 2 Decomposition × Learning System Integration

### Current Problem (Phase 1-2)

**Phase 1 (Parsing)**:
- User adds: "Call dentist"
- LLM extracts: title, due_date, priority
- Task created: auto-create (no learning feedback yet)

**Phase 2 (Decomposition)**:
- User adds: "Implement authentication system"
- LLM breaks into: 3 subtasks, effort estimates, dependencies
- Subtasks created: auto-create (no learning feedback yet)
- **Missing**: How does LLM improve over time?

### Opportunity: Integrate FSRS Learning into Decomposition

Instead of treating decomposition as one-off, model it as a **learnable skill** with FSRS-style feedback:

```
Decomposition Quality as Learnable
──────────────────────────────────

Step 1: LLM suggests breakdown
  ↓ FSRS card analog: "How should we break down [task type]?"

Step 2: Abby works the subtasks
  ↓ Collects actual data: effort_actual vs effort_estimated, dependencies that held, missing steps

Step 3: Review collected data
  ↓ Grade the decomposition (1-5 stars, same as Learning Bot)

Step 4: System learns from feedback
  ↓ "For marketing tasks, I underestimate effort by 20%"
  ↓ "Dependencies are usually correct"
  ↓ "I miss 'documentation' step 40% of the time"

Step 5: Next decomposition uses learned patterns
  ↓ Adjust prompts based on accuracy history
  ↓ Personalize by task type, complexity, user preferences
```

### Design: Decomposition Card System

Model each decomposition as a "learning card" in FSRS:

```elixir
schema "decomposition_cards" do
  # Decomposition identity
  field :task_id, :uuid
  field :task_title, :string
  field :task_complexity, Ecto.Enum, values: [:simple, :moderate, :complex]

  # Predicted (from LLM)
  field :predicted_subtask_count, :integer
  field :predicted_total_effort_hours, :float
  field :predicted_dependencies, :map

  # Actual (collected from user's completion)
  field :actual_subtask_count, :integer
  field :actual_total_effort_hours, :float
  field :actual_dependencies, :map
  field :missing_subtasks, {:array, :string}
  field :extra_subtasks, {:array, :string}

  # FSRS Scheduling (same as Learning Bot cards)
  field :stability, :float, default: 0.0
  field :difficulty, :float, default: 0.0
  field :due_at, :utc_datetime
  field :review_count, :integer, default: 0
  field :last_grade, :integer  # 0-3: again/hard/good/easy

  # Grading & Feedback (Phase 3)
  field :user_rating, :integer  # 1-5 stars
  field :user_feedback, :text
  field :confidence_grade, :integer  # 0-3 FSRS grade

  # Metadata for learning
  field :source_domain, :string  # "marketing", "engineering", "operations"
  field :source_complexity_estimate, :string
  field :decomposition_timestamp, :utc_datetime

  timestamps()
end
```

**Why FSRS Model?**
- Learning Bot already uses FSRS
- Same `stability/difficulty/due_at/review_count` schema
- Could potentially share learning infrastructure later
- User already familiar with FSRS grading (1-4 scale)

---

## Phase 2 Architecture with Learning Integration

### Current Phase 2 Design

```
DecompositionHandler
  ↓
llm.inference.chain (3 steps)
  ↓
Subtasks created → TaskStore
  ↓
gtd.task.created events published
```

### Enhanced Phase 2 Design (Anticipating Phase 4 Learning)

```
DecompositionHandler
  ↓
llm.inference.chain (3 steps)
  ↓
Create DecompositionCard (FSRS structure)
  ├─ Store predicted values
  └─ Mark as due_at: now (ready for user action)
  ↓
Subtasks created → TaskStore
  ├─ Link to decomposition_id
  └─ Track parent_task relationship
  ↓
gtd.task.created events published
```

### Phase 3: Collect Feedback (Learning Readiness)

```
User completes all subtasks
  ↓
TaskHandler.handle_complete (all subtasks done)
  ↓
[NEW] DecompositionReviewHandler
  ├─ Gather: actual_subtask_count, actual_effort_hours
  ├─ Compare: predicted vs actual
  ├─ Calculate: accuracy metrics
  └─ Publish: decomposition.review event
      ↓
[NEW] DecompositionReviewQueue (similar to Learning Bot review)
  ├─ Show user: "Estimated 12 hours, took 8 hours"
  ├─ Ask for rating: "Was the decomposition helpful?"
  └─ Collect feedback (1-5 stars + optional notes)
      ↓
Store rating in DecompositionCard.last_grade (0-3 FSRS scale)
Store feedback in DecompositionCard.user_feedback
```

### Phase 4: Learn from Feedback (Like Learning Bot Personalization)

```
LearningSystemAnalyzer (new module)
  ├─ Queries all DecompositionCards
  ├─ Groups by: task_type, complexity, user
  ├─ Calculates:
  │   - Accuracy: (predicted vs actual) by field
  │   - Confidence: based on user ratings
  │   - Personalization: user-specific biases
  └─ Updates decomposition prompts
      ↓
Future Decompositions Use Learned Patterns:
  ├─ For Abby: "Add 30% buffer to engineering estimates"
  ├─ For Abby: "Always check for documentation step"
  ├─ For complex tasks: "Break into 5-8 subtasks, not 3-5"
  └─ Confidence threshold auto-adjusts (like Learning Bot)
```

---

## FSRS Grade Mapping

### Learning Bot → Decomposition Card

Learning Bot uses:
- `again` (0): Wrong or needs immediate rework
- `hard` (1): Correct but difficult recall
- `good` (2): Correct and timely
- `easy` (3): Correct and effortless

Decomposition mapping:
```elixir
def decomposition_to_fsrs_grade(user_rating, accuracy_delta) do
  case {user_rating, accuracy_delta} do
    # User rated 1-2 stars or massively wrong
    {rating, delta} when rating < 3 or delta > 0.3 -> 0  # again

    # User rated 3 stars or moderate error (20-30% off)
    {3, delta} when delta > 0.2 -> 1  # hard

    # User rated 4 stars or within 20%
    {rating, delta} when rating == 4 and delta < 0.2 -> 2  # good

    # User rated 5 stars and accurate
    {5, delta} when delta < 0.1 -> 3  # easy

    # Default
    _ -> 2  # good (neutral)
  end
end
```

This allows:
- Decomposition cards to use FSRS scheduler
- Learned patterns to reinforce frequently
- Accuracy trends to drive prompt personalization

---

## Implementation Roadmap

### Phase 2: Task Decomposition (v0.3.0) - Current
- ✅ DecompositionHandler
- ✅ llm.inference.chain calls
- 🏗️ DecompositionCard schema (bake in, don't use yet)
- 🏗️ Store predicted values (for Phase 3 comparison)
- ✅ Link subtasks to decomposition_id (for traceability)

### Phase 3: Decomposition Review & Feedback (v0.4.0)
- ⏳ DecompositionReviewHandler
- ⏳ Collect actual vs predicted data
- ⏳ DecompositionReviewQueue (review before grading)
- ⏳ FSRS grade calculation from user feedback
- ⏳ Publish decomposition.review events

### Phase 4: Learning System (v1.0)
- ⏳ LearningSystemAnalyzer
- ⏳ Accuracy tracking by task type / complexity
- ⏳ Personalized prompt generation
- ⏳ Confidence threshold adjustment (FSRS-based)
- ⏳ Cross-domain patterns (marketing vs engineering)

### Phase 5: Learning Bot Integration (Future)
- ⏳ DecompositionCard scoring could feed Learning Bot
- ⏳ If Abby weak on "task decomposition", Learning Bot could surface related skill-building cards
- ⏳ "Decomposition" becomes a learnable skill

---

## Why This Matters for Phase 2 Design

Even though we don't implement the learning system in Phase 2, **designing with it in mind** prevents later refactoring:

### What to Bake Into Phase 2

1. **DecompositionCard Schema**
   - Store FSRS fields (stability, difficulty, due_at, review_count, last_grade)
   - Add accuracy tracking fields (predicted vs actual)
   - No processing yet, just storage structure

2. **Task-Decomposition Linking**
   - Each subtask knows its parent decomposition_id
   - Enables future: "Undo this decomposition and try again"
   - Enables tracking: "How did this breakdown perform?"

3. **Metadata Capture**
   - Task type / domain (marketing, engineering, etc.)
   - User complexity estimate (simple/moderate/complex)
   - Timestamp for correlation

4. **Predicted Values Storage**
   - Save: `predicted_subtask_count`, `predicted_effort_hours`, `predicted_dependencies`
   - Phase 3 compares these to actuals
   - Phase 4 learns from deltas

### What to Skip in Phase 2

- ❌ FSRS scheduling (activate in Phase 3)
- ❌ User rating collection (add in Phase 3)
- ❌ Learning analysis (build in Phase 4)
- ❌ Prompt personalization (Phase 4+)

**Cost to Bake In**: 10 minutes of schema design
**Cost to Add Later**: 2-3 hours refactoring if not planned

---

## Conceptual Diagram: Learning System in Bot Army

```
Learning Bot
├─ FSRS scheduler (core engine)
├─ DecompositionCard scoring (future)
└─ Feeds: "Abby struggles with task decomposition"

    ↓ Context signal

Context Broker
└─ Marks context as: :task_decomposition_session_time

    ↓ Routes learning material

GTD Bot
├─ Task decomposition requests
├─ Collects: actual vs predicted
└─ Feeds back: accuracy metrics

    ↓ Learning signal

Learning Bot (Phase 5 future)
├─ Surfaces related skill cards
│   ├─ "5-step decomposition template"
│   ├─ "Effort estimation heuristics"
│   └─ "Task dependency patterns"
└─ Tracks: "Decomposition accuracy improving week-over-week"
```

---

## Key Takeaway for Phase 2 Design

**Do not:**
- ❌ Auto-delete decomposition history
- ❌ Flatten predicted/actual values (lose signal)
- ❌ Avoid FSRS field schema (just leave unused)

**Do:**
- ✅ Store decomposition metadata with task links
- ✅ Plan for Phase 3 feedback collection
- ✅ Design schema anticipating FSRS learning (Phase 4)
- ✅ Reference Learning Bot north star when designing Phase 4

This ensures when Learning Bot is built (Phase 5+), GTD × Learning integration is seamless and data-rich.

---

## Questions for Implementation

1. **Should Phase 2 decompositions get a config flag** (like parsing did)?
   - `:auto_create` (current)
   - `:with_learning_prep` (future-proofed schema)
   - Recommendation: Bake in `:with_learning_prep` structure, no functional change

2. **Should decomposition_id be optional in TaskStore early?**
   - Yes - allows non-decomposed tasks to exist (manual creation, from parsing)
   - Link is optional but captured when available

3. **When should we move "decomposition cards" into Learning Bot?**
   - Not Phase 2-4
   - Phase 5 (when Learning Bot is being built)
   - Could be a data migration from GTD → Learning Bot tables


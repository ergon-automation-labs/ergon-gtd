# Dotfiles GTD System Learnings (~/code/dotfiles)

## Context
The dotfiles GTD system (v2.0) is a mature, production GTD implementation with:
- ~75+ bash scripts
- RabbitMQ-based background workers
- Vector embeddings (pgvector) for semantic search
- AI-powered task generation and organization
- Human-in-the-loop review interface ("Command Center")
- 2+ years of lessons learned

---

## Key Architectural Patterns Worth Considering

### 1. **Human-in-the-Loop Review Interface** (Critical Learning)

**Current Implementation**:
- Command Center: Menu-driven interface for AI suggestions
- All automation goes through human review before applying
- Nuanced feedback: 1-5 star ratings (not just accept/reject)
- Explainability: Shows confidence scores and reasoning

**Applicability to bot_army_gtd**:
- ✅ Phase 2: Instead of auto-applying parse results, create a "suggested tasks" queue
- ✅ User reviews & approves parsed tasks before TaskStore.create
- ✅ Rating feedback (1-5 stars) trains LLM parsing improvements
- ⏳ Future: Surface in REST API or TUI for review

**Benefits**:
- Safety: Humans maintain control over final task creation
- Learning: Rating feedback improves parsing accuracy over time
- Trust: Users understand why system made suggestions
- Personalization: System learns user's organization preferences

**Implementation Sketch**:
```
gtd.inbox.add → llm.response.parse (LLM bot)
  ↓
llm.response.parsed → InboxParsingHandler
  ↓
Create SuggestionQueue entry (not task yet)
  ↓
Command Center shows: "Parsed Task: 'Call dentist' (Confidence: 92%)"
User action: Accept (★★★★★) / Reject (★) / Skip
  ↓
Feedback → gtd.task.review event (for learning)
  ↓
If accepted → Create task in TaskStore
If rejected → Create negative example for training
```

### 2. **Semantic Search via Vector Embeddings**

**Current Implementation**:
- PostgreSQL + pgvector (Nomic embed-text v2, 768 dimensions)
- Markdown chunking: Header boundaries, paragraph fallback
- Metadata tagging: project, category, tags array
- Hybrid search: vector similarity + metadata filters

**Applicability to bot_army_gtd**:
- ⏳ Phase 3+: "Find similar tasks" feature
- ⏳ "Auto-detect project" by semantic similarity to existing tasks
- ⏳ "Suggest related open tasks" when creating new one

**Relevant Parameters**:
- Embedding model: Nomic embed-text v2 (768-dim, ~250 dimensions larger than many alternatives)
- Chunking: max_tokens=512, overlap_tokens=50
- Context enrichment: Prepend metadata (document path, section hierarchy) before embedding

### 3. **Unified Learning System** (Highly Relevant)

**Current Implementation**:
- Single learning system (`gtd_unified_learning.py`) tracks all suggestion types
- Pattern: user feedback (accept/reject/rating) → store in learning database
- Cross-domain intelligence: patterns learned in one area inform others
- Automatic threshold adjustment based on acceptance rate

**Applicability to bot_army_gtd**:
- ✅ Phase 2: Track parsing accuracy by task type, user, time
- ✅ Adjust confidence thresholds: if >80% acceptance, show lower-confidence suggestions
- ✅ If <50% acceptance, raise threshold or flag for retraining
- ✅ Learn which fields users care about most (title vs. due_date vs. project)

**Example Metrics**:
```
parsing_accuracy_by_user: {
  "alice": {"avg_rating": 4.2, "acceptance_rate": 0.92},
  "bob": {"avg_rating": 2.8, "acceptance_rate": 0.56}
}

parsing_accuracy_by_field: {
  "title": 0.98,        # Consistently accurate
  "due_date": 0.72,     # Often wrong
  "project": 0.85       # Moderately accurate
}

confidence_threshold: 0.65  # Auto-adjusted based on feedback
```

### 4. **Async Background Workers with Graceful Degradation**

**Current Implementation**:
- RabbitMQ queue-based message passing
- Long-running workers (not cron jobs)
- Failure logging to `/tmp` (simple but needs monitoring)
- No automatic alerting on crashes

**Applicability to bot_army_gtd**:
- ✅ Already have NATS (similar to RabbitMQ, event-based)
- ✅ Workers: parsing handler, learning aggregator, suggestion reviewer
- ⏳ Add worker health monitoring to NATS Consumer
- ⏳ Surface worker status in metrics/logs

**Better Approach for bot_army**:
- Use NATS as queue (already built in)
- Structured logging (logger_json) instead of `/tmp` files
- Health checks: periodic heartbeat events
- Monitoring: track success/failure rates per handler

### 5. **Freeform Logging → Structured Organization Pipeline**

**Current Implementation**:
- `gtd-log "freeform text"` → writes to log file
- File watcher triggers vectorization
- Background workers: generate tasks, suggest projects, detect patterns
- Results surface in Command Center for human review

**Applicability to bot_army_gtd**:
- ✅ gtd.inbox.add is the "log" entry point
- ✅ Phase 1: Parse text into structured fields
- ✅ Phase 2: Review suggestions before creating tasks
- ✅ Phase 3: Learn from patterns ("tasks always assigned to same project")

**Enhancement Opportunity**:
Instead of single parse → auto-create flow, could build:
1. Parse candidate tasks from inbox
2. Show top 3 suggestions with confidence scores
3. Let user pick the best one (or custom edit)
4. Rate quality of parse (1-5 stars)
5. System improves from feedback

### 6. **Caching to Prevent Duplicate Processing** (Known Issue Worth Fixing)

**Current Problem**:
- System re-processes same files on restart
- No caching of AI suggestions
- Wastes API calls and processing time

**Applicability to bot_army_gtd**:
- ⏳ Add inbox_item cache: `(item_id, content_hash) → parsed_result`
- ✅ Check cache before publishing llm.response.parse
- ✅ Store parse results with timestamp, invalidate after 7 days
- ✅ Prevent duplicate work if system restarts

**Simple Cache Table**:
```
gtd_parse_cache (
  inbox_item_id: UUID,
  content_hash: string,    -- SHA256(raw_text)
  parsed_result: JSON,
  confidence_score: float,
  created_at: timestamp,
  expires_at: timestamp    -- 7 days from creation
)

Key: (item_id, content_hash)
```

### 7. **Rate Limiting to Prevent LLM Overload** (Known Issue Worth Fixing)

**Current Problem**:
- Can overwhelm local model endpoints
- Causes timeouts and failures
- Solution (ollama-controller-api) was abandoned

**Applicability to bot_army_gtd**:
- ✅ Implement token bucket rate limiting on llm.response.parse requests
- ✅ Limit to N requests per minute (e.g., 10/min per user, 100/min globally)
- ✅ Queue excess requests in NATS, process when capacity available
- ✅ Return 429 (rate limit) with backoff hint if throttled

**Simple Implementation**:
```
gtd.inbox.add
  ↓
Check rate limit (user + global)
  ↓
If under limit: publish llm.response.parse immediately
If over limit: queue in NATS with 30-second retry
  ↓
Return to user: "Task queued for parsing" instead of blocking
```

---

## Comparison: Dotfiles GTD vs bot_army_gtd

### Current State (bot_army_gtd v0.2.0)

| Feature | Dotfiles | bot_army_gtd |
|---------|----------|--------------|
| **Storage** | Markdown files + PostgreSQL | PostgreSQL only |
| **Sync** | Obsidian Sync | No sync (embedded in system) |
| **Task Logging** | `gtd-log` CLI | NATS events (gtd.inbox.add) |
| **Parsing** | AI in background workers | LLM bot (async via NATS) |
| **Review Interface** | Command Center menu | None yet |
| **Learning System** | Unified learning system | None yet |
| **Vectorization** | pgvector embeddings | None yet |
| **Caching** | None (known issue) | None yet |
| **Rate Limiting** | None (known issue) | None (not blocking) |
| **Home/Work Mode** | Yes | No |

---

## Recommended Implementation Phases

### Phase 1: ✅ DONE (Current)
- Basic inbox parsing with LLM
- No review interface (auto-create tasks)

### Phase 2: 🎯 NEXT (Task Review Queue)
- Add suggestion review before task creation
- 1-5 star rating feedback
- Track parsing accuracy per field
- Implement caching layer

### Phase 3: 🔄 FUTURE (Learning & Personalization)
- Unified learning system (like dotfiles)
- Threshold adjustment based on feedback
- Personalized parsing (learn user preferences)
- Rate limiting if needed

### Phase 4: 🔄 FUTURE (Advanced Features)
- Vector embeddings for semantic search
- "Find similar tasks" feature
- Auto-project suggestion based on similarity
- Cross-user pattern detection (if multi-user)

---

## Anti-Patterns to Avoid (From Dotfiles Issues)

### 1. ❌ **No Duplicate Detection**
- **Problem**: Same file processed multiple times
- **Solution**: Cache with content hash
- **Implementation**: Add parse_cache table, check before publishing parse request

### 2. ❌ **No Rate Limiting**
- **Problem**: Overwhelms LLM endpoint, causes timeouts
- **Solution**: Token bucket rate limiting per user/global
- **Implementation**: NATS queue with backoff, not critical for v0.2.0 but needed for scale

### 3. ❌ **No Health Monitoring**
- **Problem**: Workers crash silently, issues go unnoticed
- **Solution**: Periodic heartbeat events, track success/failure rates
- **Implementation**: Simple counters in Logger output, visible in logs

### 4. ❌ **No Separate Dev/Prod**
- **Problem**: All changes tested in production
- **Solution**: Use test environment, run tests before deploy
- **Good News**: We have this already (mix test)

### 5. ❌ **No Documentation Sync with Code**
- **Problem**: Docs get stale, AI learns incorrect patterns
- **Solution**: Keep CLAUDE.md + README.md updated with code changes
- **Good News**: We're doing this already

---

## Specific Ideas to Implement NOW

### Idea 1: Confidence Scores in Parse Results
**Effort**: 10 minutes (in bot_army_llm ResponseHandler)

```elixir
# Current response:
%{
  "structured_data" => %{"title" => "...", "project" => "..."}
}

# Enhanced response (from LLM):
%{
  "structured_data" => %{...},
  "field_confidence" => %{
    "title" => 0.95,
    "project" => 0.72,
    "due_date" => 0.43
  },
  "overall_confidence" => 0.87
}
```

**Benefit**: InboxParsingHandler can show user: "I'm 87% confident about this task"

### Idea 2: Cache Layer for Inbox Parsing
**Effort**: 30 minutes (add to bot_army_gtd)

```elixir
# Before publishing llm.response.parse:
case InboxParseCache.get_by_content_hash(content_hash) do
  {:ok, cached} ->
    # Return cached result instead of parsing again
    InboxParsingHandler.process_cached(inbox_item_id, cached)
  :not_found ->
    # Proceed with llm.response.parse as normal
    publish_parse_request(...)
end
```

**Benefit**: Prevent redundant LLM calls, faster response for repeated tasks

### Idea 3: Tracking Parsing Accuracy by Field
**Effort**: 45 minutes (simple metrics tracking)

```elixir
# After user approves/rejects parse:
ParsingMetrics.record(%{
  user_id: user_id,
  field: "title",
  predicted: "Call dentist",
  user_edited: "Call dentist (2pm)",
  rating: 4,  # 1-5 stars
  timestamp: now
})

# Later, query accuracy:
ParsingMetrics.accuracy_by_field("title")  # => 94%
ParsingMetrics.accuracy_by_user("alice")   # => 88%
```

**Benefit**: Know which parsing is working well vs. needs improvement

---

## Long-term Vision (Taking Ideas from Dotfiles)

**Year 1**:
- ✅ v0.2.0: Inbox parsing (current)
- ⏳ v0.3.0: Task review queue + rating feedback
- ⏳ v0.4.0: Learning system (accuracy tracking, threshold adjustment)

**Year 2**:
- Task decomposition (multi-step)
- Task clarification (multi-turn conversations)
- Semantic search (vector embeddings)
- Cross-task pattern detection

**Year 3**:
- Multi-user learning ("best practices" from all users)
- Predictive task suggestions ("you usually create tasks like X on Mondays")
- Automated cleanup (archive old completed tasks)
- Integration with other systems (calendar, email)

---

## Questions for Implementation

1. **Should Phase 2 include a review interface, or keep auto-creating tasks?**
   - Dotfiles learnings suggest human review = trust + learning
   - But could skip for now, add later

2. **Do we want per-user accuracy tracking?**
   - Simple to implement (just logs with user_id)
   - Enables personalization later
   - Worth the small overhead?

3. **Caching layer - implement now or wait?**
   - Simple to add (content hash + table)
   - Prevents redundant LLM calls
   - Should probably be in Phase 1.5

4. **Vector embeddings - future consideration?**
   - Requires adding embeddings to bot_army_llm
   - Enables "similar tasks" feature
   - Worth exploring, not critical for v1.0

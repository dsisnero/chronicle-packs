# Conversation-driven long-term memory

The assistant builds and uses durable, cross-session memory by connecting the
**Chat Pack** to the **Memory Gateway** lifecycle. Out of the box this works
with **no LLM, no API key, and no external service** — and every piece is a
swappable seam.

```text
chat turn ──▶ memory_candidate ──▶ evaluation ──▶ memory_item ──▶ (backend)
   write path        contract        governance      stored          recall
                                                                        │
new chat turn ◀── prompt ◀── memory_context ◀── retrieve_memories ◀────┘
   read path
```

There are three independent seams, each described below:

1. **Write path** — how a chat turn becomes a memory candidate.
2. **Backend** — where memories are stored and how they are recalled.
3. **Embeddings** — lexical recall by default, vector recall when you opt in.

---

## 1. The default write path (zero-LLM heuristic)

`chat_memory_proposer` (in `src/chronicle_packs/chat/behaviors.cr`) inspects
each inbound chat message and, when it states something durable (a preference,
instruction, decision, or first-person fact), emits a `memory_candidate`. It
is a small, explainable keyword heuristic — see
`MemoryCues::CHAT_MEMORY_CUES` — chosen so that the assistant builds memory at
**zero cost**.

Core's generic `source → observation → memory_candidate` pipeline also proposes
candidates from the same message. Running both is safe: `memory_writer`
deduplicates by normalized text (`Backend._normalize_text` via
`Backend.find_by_text`), so the same statement is never stored twice.

Governance is unchanged: `candidate_evaluator` accepts a candidate when its
confidence clears `MemoryGatewaySettings.acceptance_threshold` (or its category
is in `auto_accept_categories`). Nothing is written directly — everything goes
through the candidate → evaluation → item lifecycle.

### Swapping in a different ingestion strategy

The contract is the `memory_candidate` object. **Any** pack that emits
`memory_candidate` objects feeds the same lifecycle, so you can replace the
heuristic without editing the Chat Pack:

1. Turn the default off:

   ```crystal
   settings = Chronicle::Packs::Chat::ChatSettings.new(memory_write_path: "off")
   ```

2. Load your own ingestion pack (an LLM extractor, an entity-extraction pack, a
   mem0 importer, …) whose behavior creates `memory_candidate` objects from
   whatever signal you care about — for example:

   ```crystal
   graph.add_object("memory_candidate", {
     "text"       => JSON::Any.new("Prefers async standups over live meetings."),
     "confidence" => JSON::Any.new(0.9),
     "category"   => JSON::Any.new("preference"),
     "source_ids" => JSON::Any.new([JSON::Any.new(source_id)]),
   }.to_json)
   ```

That's the whole seam — no monkey-patching, no Chat Pack changes.

---

## 1b. Curation: what deserves to be memory (v0.2)

The plumbing decides *how* memories flow; curation decides *what* gets in.
Three guards, all on by default:

- **Questions are not memory.** Both write paths skip interrogatives —
  "What's my favorite color?" is classified as a question and dropped, while
  "My favorite color is green" is stored. (`Chat._is_question` checks `?` and
  the `MemoryCues::INTERROGATIVE_STARTS` list; Core checks `?` before keyword
  categories.)
- **Provenance admission — documents don't give orders.** The evaluator
  (the lifecycle's governance point, `MemoryGateway._provenance_verdict`)
  admits conversational sources freely (the reply gate already governs who
  converses, and the memory is subject-scoped to the speaker), but guidance
  categories (`Admission::GUIDANCE_CATEGORIES`: instruction/preference/decision)
  extracted from non-conversational content (emails, documents, tool results)
  are rejected — with a written rationale on the evaluation object — unless
  the sender resolves to a trusted principal
  (`Admission::TRUSTED_ROLES`: owner/admin/collaborator). Enforced only when
  the Identity/Auth Pack has registered principals; without identity, behavior
  is unchanged. Knobs: `MemoryGatewaySettings.provenance_admission`
  (`"trusted_senders"` | `"off"`).
- **Frame-scoped recall.** Items record the frame they were born in, and
  chat recall excludes the asking frame (`exclude_frame_id`), so a memory
  created by the current turn can never answer it — a designed invariant,
  not a cascade-ordering accident.

Category priority is also real now: candidates in
`auto_accept_categories` accept at `auto_accept_min_confidence` (default
0.5) instead of the full `acceptance_threshold` (default 0.6).

## 2. Using memory (recall) and the backend

`chat_memory_context` (in `src/chronicle_packs/chat/behaviors.cr`) runs **before**
the LLM responder on every inbound chat message. It calls
`Chronicle::Packs::MemoryGateway.retrieve_memories_fn`, attaches the top
matches to the message as a `memory_context` object, and the responder's scoped
graph view folds that text straight into the prompt — the same mechanism used
for conversation history and the assistant's identity.

It is bounded and configurable via `ChatSettings`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `include_memory` | `true` | Master switch for cross-session recall. |
| `memory_write_path` | `"heuristic"` | `"heuristic"` or `"off"` (see §1). |
| `memory_backend_url` | `":memory:"` | Backend to recall from — **must match** `MemoryGatewaySettings.backend_url`. |
| `memory_top_k` | `3` | Max memories folded into the prompt. |
| `memory_min_score` | `0.1` | Minimum similarity score to recall. |
| `memory_subject_scoped` | `true` | Recall only the message sender's own memories (see below). |
| `memory_include_global` | `false` | When subject-scoped, also recall subject-less "global" memories. |

```crystal
settings = Chronicle::Packs::Chat::ChatSettings.new(
  include_memory: true,
  memory_write_path: "heuristic",
  memory_backend_url: ":memory:",
  memory_top_k: 3,
  memory_min_score: 0.1,
  memory_subject_scoped: true,
  memory_include_global: false,
)
```

### Multi-user isolation (subject scoping)

Recalled memory is folded straight into the LLM prompt, so **recall is an
access-control boundary**: in a multi-user deployment one user must never receive
another user's memories. Two mechanisms enforce this:

- **Writes are tagged with their author.** Every memory carries a `subject_ref`
  (the originating `sender_ref`). The heuristic write path sets it directly; for
  candidates from Core's generic extraction path (which don't set it),
  `memory_writer` derives it from the candidate's source object
  (`MemoryGateway._derive_subject_ref`). A memory with no resolvable author
  stays subject-less (genuinely global).
- **Reads are scoped to the sender.** With `memory_subject_scoped: true`
  (default), `chat_memory_context` passes the inbound message's `sender_ref` and
  only recalls memories tagged for that user. `memory_include_global: false`
  (default) keeps recall **strict** — only the sender's own memories — so
  untagged or legacy subject-less rows can never leak across users. Set
  `memory_include_global: true` to also surface shared/global facts to everyone,
  or `memory_subject_scoped: false` for a single-user assistant where every
  memory is shared.

At the backend, `Backend.retrieve_by_query(subject_ref:, subject_scoped:,
include_global:)` applies the same filter, so alternative read paths inherit the
boundary.

### Persistence across sessions

Recall reads the **same store** that the writer persists to. In the Crystal
port the store is the graph: `memory_item` objects ARE the memory backend
(`src/chronicle_packs/memory_gateway/backend.cr`). `backend_url` fields exist
for configuration parity with the vendor, but the ported backend scans graph
objects; it does not open an external datastore from that URL. To make
memories survive a restart, run against a persisted Chronicle event store (for
example `Chronicle::SQLiteEventStore`), which persists the graph objects the
backend reads:

```crystal
memory_settings = Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(
  backend_url: "data/memory.sqlite",
)
chat_settings = Chronicle::Packs::Chat::ChatSettings.new(
  memory_backend_url: "data/memory.sqlite",
)
```

The Crystal demo server wires chat + memory into a runtime; with a persistent
event store the memories written in one session are recalled in the next.

### Plugging in an external backend (mem0, Zep, pgvector, Supermemory, …)

**Not ported.** The vendor exposes a first-class `MemoryBackend` protocol with
`store_item` / `retrieve_by_query`, a `register_backend` scheme registry, an
`ExternalMemoryBackend` base, and a mem0 adapter. In this Crystal port the
`MemoryGateway::Backend` is graph-backed only; the external-backend seam and
the mem0/Zep/pgvector/Supermemory adapters are deferred. Adding one is a host
seam: keep graph objects authoritative and route only recall acceleration or
mirroring through the application. See
[intentional divergences](../plans/parity.md#intentional-divergences).

---

## 3. Recall scoring: hybrid lexical + embeddings

Every item always gets a **lexical score**: `max(Jaccard overlap, query-term
coverage)` (`Backend.lexical_score`). Coverage — the fraction of the *query's*
content words present in the stored text — is what makes short and natural
queries work: `"teal"` against *"my favorite color is teal and I run a bakery
called Crumbtown"* scores 1.0 (Jaccard alone gives ~0.14 and misses the default
threshold — the exact failure the July 2026 evaluation caught). Interrogative
and function words (`Backend::STOPWORDS`) are treated as stopwords so questions
don't dilute their own coverage. Dependency-free, never errors, no API key.

With an embedder registered, items are embedded at write time and recall adds
a **cosine signal**; an item's score is the **max of the two signals** — a
memory is as relevant as its strongest signal. Embeddings add rephrasing
recall ("what theme do I like?" → *"I prefer dark mode"*) without ever
costing exact-keyword recall, and items without a vector (stored before the
embedder existed, or if embedding fails) simply keep scoring lexically. Both
signals share the `[0, 1]` scale (`Backend._cosine` clamps to it), so one
`min_score` governs everything.

The pack never instantiates a provider directly. Embedding calls go through a
small recorded interface, `MemoryGateway::EmbeddingService`, bound per runtime
graph so configuration never leaks across instances. Crig computes vectors;
Chronicle makes the call durable and replayable (`embedding.requested` /
`embedding.responded`, idempotency-keyed); Memory Gateway decides memory
semantics (`writes`/recall ranking/persistence/fallback).

```crystal
embedder = Chronicle::Packs::MemoryGateway::HashEmbedder.new(256)
service = Chronicle::Packs::MemoryGateway::RecordedEmbeddingService.new(
  graph, embedder,
)
Chronicle::Packs::MemoryGateway::Backend.set_embedding_service(graph, service)
```

`RecordedEmbeddingService` is the reference recorded implementation: it emits
durable `embedding.requested` / `embedding.responded` events on the bound graph
and replays a prior result from the log by idempotency key, with zero provider
contact on replay. Any object with `embed(texts, model)` (subclass
`MemoryGateway::Embedder`) works via `Backend.set_embedder(...)`; the
process-global form and the environment-driven factory remain available:

```crystal
Chronicle::Packs::MemoryGateway::Backend.set_embedder_factory(
  -> { Chronicle::Packs::MemoryGateway.default_embedder_factory }
)
Chronicle::Packs::MemoryGateway::Backend.auto_configure_embedder
# embedding recall iff OPENAI_API_KEY is set
```

`OpenAIEmbedder` is implemented with stdlib HTTP (honors `OPENAI_BASE_URL`,
model via `ACTIVEGRAPH_EMBEDDING_MODEL`), so the pack still has **zero
embedding dependencies**; provider failure or an unavailable replay degrades
to lexical and never errors. `HashEmbedder` (deterministic, no network) is
what fixtures and tests use to exercise the vector path.

**Embedding-space identity is stored on the item** (`embedding_model`,
`embedding_dimensions`, `embedding_version`). Recall only adds cosine when the
item's model AND version match the query embedding's space; a model/version
change lexical-fallbacks those entries. Never cosine-compare across spaces.

---

## Verifying it works

- `crystal spec spec/chronicle_packs/chat_spec.cr` — the write/read behaviors
  (`chat_memory_proposer` + `chat_memory_context`), including the question
  skip and subject stamping.
- `crystal spec spec/chronicle_packs/memory_retrieval_quality_spec.cr` — the
  regression suite built from the July 2026 evaluation's verified recall
  failures ("teal", "bakery", rephrased questions), plus the hybrid-scoring
  guarantees.
- `crystal spec spec/chronicle_packs/memory_subject_scoping_spec.cr` — the
  multi-user isolation boundary.
- `crystal spec spec/chronicle_packs/memory_embedders_spec.cr` — the embedding
  seam (vector recall, lexical fallback, no-key safety).
- `crystal spec spec/chronicle_packs/memory_gateway_spec.cr` — the lifecycle,
  dedup, and retrieval contract.

A preference written in one session is recalled in a fresh session when both
share a persisted runtime/event store; the Python
`chat_memory_cross_session.py` fixture maps to the portable specs above.

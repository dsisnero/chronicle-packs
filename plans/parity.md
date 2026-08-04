# chronicle-packs — activegraph-packs Crystal Port

Upstream: https://github.com/yoheinakajima/activegraph-packs
Revision: 6639a5385518ad49f74813373c85cf96eff9adc0 (main, pinned)
Language: python (regex inventory backend, approximate)

The upstream is the official pack library for the ActiveGraph reactive
object-graph runtime: 19 packs plus a bridge pack, importers, bundles, and a
demo server. Pack `__init__.py` files export a `Pack(...)` object and a
settings class; object/relation types are Pydantic schemas; behaviors and
tools are decorator-driven handlers. A port is behavior-faithful when the
manifest-declared surface (object types, relation types, behaviors, tools,
settings schema) and the deterministic behaviors match upstream.

Porting order below is tiered: Core first (universal substrate), then the
infrastructure packs it is required by, then communication, then domain
verticals, then transport adapters and the demo surface.

## Features

### Tier 0 — Project baseline

- [x] Pack manifest format + loader (TOML `manifest.toml`, `[pack]`, `[dependencies]`, `[surface]`, `[fixtures]`) — validate a pack's declared surface against its code — provided by the chronicle runtime (`Chronicle::Packs`), verified byte-exact against all 33 upstream manifests (`spec/chronicle_packs/vendor_manifests_spec.cr`)
- [ ] Pack scaffolding convention: `__init__.py`, `object_types.py`, `behaviors.py`, `tools.py`, `settings.py`, `fixtures/`, `README.md`, `CHANGELOG.md`
- [x] Core pack settings (`CoreSettings`) and deterministic fixture runner pattern (`fixtures/run_fixtures.py`) — `src/chronicle_packs/core/settings.cr`, `src/chronicle_packs/fixture_runner.cr`

### Tier 1 — Core pack (packs/core)

- [x] 7 object types: source, observation, task, action, artifact, memory_candidate, evaluation — `src/chronicle_packs/core/object_types.cr`
- [x] 7 relation types: grounds, produces, executes, generates, proposes, evaluates, derived_from, derived_from_source — `src/chronicle_packs/core/relation_types.cr`
- [x] Behavior `observation_extractor` — sentence/word-based observation extraction from sources — `src/chronicle_packs/core/behaviors.cr`
- [x] Behavior `task_linker` — links observations to candidate tasks — `src/chronicle_packs/core/behaviors.cr`
- [x] Behavior `memory_candidate_proposer` — proposes memory candidates from observations — `src/chronicle_packs/core/behaviors.cr`
- [x] Core fixture scenarios run deterministically with no API key — all 3 vendor scenarios pass (`spec/chronicle_packs/core_fixtures_spec.cr`)

### Tier 2 — Infrastructure packs

- [ ] `tool_gateway` — capability registry, approval policy (risk_class gating), execute/spec/pending-approvals tools, catalog, standing scopes, untrusted-content injection scan
- [ ] `secrets` — credential reference management (managed source registry, no secrets in context)
- [ ] `memory_gateway` — candidate evaluation/promotion, SQLite backend, retrieval ranking, embedder seam (default deterministic, mem0 adapter optional)
- [ ] `identity_auth` — principal resolution, role-based access, permission checking
- [ ] `agent_profile` — goals, personality, standing instructions scoped by channel/audience
- [ ] `entity` — canonical extraction + dedup for people/orgs/projects/products/repos
- [ ] `activity_normalizer` — provider-neutral evidence identity, replay modes/revisions, deterministic candidate extraction
- [ ] `semantic_extraction` — typed source-anchored annotations, extraction_profile config, deterministic floor + LLM upgrade seam, coverage tracking
- [ ] `usage` — source surfaces, connector handoffs, stable cursors, settlement, interaction facts
- [ ] `connector_control` — service/account/surface status, run adapters, learning deltas, family-native read shapes
- [ ] `attention` — engagement observations, bounded session batches
- [ ] `skills` — skill lifecycle + verification/replay
- [ ] `eval_outcome` — evaluation outcome tracking
- [x] `llm_provider` — provider resolution (explicit > env), deterministic floor, provider seam for LLM-backed extraction — `src/chronicle_packs/llm_provider.cr`

### Tier 3 — Communication packs

- [ ] `communication` — channel-neutral threads, messages, intents, response candidates
- [ ] `chat` — sessions, memory, reply gating, agentic responses, chat_config provider resolution
- [ ] `email` — threading, dedup, draft formatting, approval-gated sends
- [ ] `schedule` — graph-native scheduling, ticks, heartbeats

### Tier 4 — Domain packs

- [ ] `research` — papers, claims, hypotheses
- [ ] `codebase` — repos, issues, PRs, architecture decisions, dependency auditing
- [ ] `team_ops` — assignments, milestones, workload estimation
- [ ] `meeting` — decision extraction, action items, summarization
- [ ] `subject_profile` — subject-centric profile tracking

### Tier 5 — Transport adapters and bridges

- [ ] `telegram` — inbound updates → chat_input; outbound policy-checked gateway sends
- [ ] `whatsapp` — WhatsApp Cloud API transport (structural mirror of telegram)
- [ ] `composio` — optional hosted Connect Links route pack
- [ ] `gmail` — connector-conformance: profiles, replayable backfill, history polling, drafts, R3-forever sends
- [ ] `mcp` — bidirectional MCP: outbound governed tools, inbound server (token auth, role-scoped exposure)
- [ ] `evolution` — agent-authored packs behind static gates, fork trials, bundle-hash pins, verified owner approval (ships disabled)
- [ ] `bridges/diligence_core` — Diligence-Core bridge mapping domain outputs to Core objects

### Tier 6 — Importers (packs/importers)

- [ ] `local_files` — local directory snapshots (category local_knowledge)
- [ ] `chatgpt_export` — official ChatGPT export ZIP, canonical paths + abandoned edit branches
- [ ] `claude_export` — flat conversations.json (ZIP or bare), same identity semantics
- [ ] `assistant_self_summary` — pasted/MCP-pushed self-summaries, injection-scanned
- [ ] `assistant_local_sessions` — Claude Code + Codex session logs, bounded recent-N window
- [ ] `public_presence` — gateway-routed, budgeted R0 fetch of owner public handles

### Tier 7 — Bundles and demo surface

- [ ] `bundles.assistant` — core + tool_gateway + secrets + memory_gateway + agent_profile + identity_auth + communication + schedule + chat
- [ ] `bundles.messaging_assistant` — assistant bundle + telegram + whatsapp
- [ ] `bundles.email_assistant` — assistant bundle + email + entity
- [ ] `bundles.research_bundle` — core + tool_gateway + memory_gateway + research
- [ ] `doctor` — noninteractive environment diagnostic (pass/fail, exit 0/1)
- [ ] `demo_server` — HTTP API surface: /summary /graph /trace /packs /frames /chat /sessions /approvals /channels /reset

## Intentional divergences

- The manifest loader/validator/hashing lives in the chronicle runtime
  shard (`Chronicle::Packs`), not in this repo — upstream owns it in
  `activegraph.packs.manifest`; chronicle ports it. This repo verifies it
  against the real upstream manifests.
- Core object type schemas are Crystal `struct` + `JSON::Serializable`
  records (matching chronicle's `@[ObjectType]` DSL contract) instead of
  Pydantic models. Pydantic field bounds (0.0–1.0 confidence, 1–100 max
  observations) are documented but not runtime-enforced.
- Event payload access is flat (`payload["id"]`, `payload["data"]`) and
  `where` predicates use flat dotted paths (`{"type" => "source"}`)
  because chronicle's `object.created` payload is flat; upstream nests
  under an `object` key. Observable behavior (objects/relations created,
  field values) is unchanged.
- `observation_extractor` guards `max_words < 1` (punctuation-only
  sources) where upstream Python would raise `ZeroDivisionError`.
- `fixtures/run_fixtures.py`'s standalone `main` CLI is not ported; the
  deterministic runner is `Chronicle::Packs::FixtureRunner`, driven by
  specs.
- `llm_provider` is a packs-level module, not a manifest pack. The
  provider `get_llm_provider` accessor is renamed `llm_provider`
  (Crystal accessor convention). `build_llm_provider` returns a
  `Chronicle::ProviderConfig` (the seam chronicle's provider factories
  consume) instead of a live client; `default_model_for` uses the same
  provider default models as upstream (`claude-sonnet-4-5` / `gpt-4o-mini`).
  The doctor-side `check_llm_provider` checks ship with the doctor
  feature (Tier 7).

## Inventory

- `plans/inventory/python_port_inventory.tsv` — 2085 API items (regex backend)
- `plans/inventory/python_source_parity.tsv` — 2085 source API items
- `plans/inventory/python_test_parity.tsv` — 558 tests

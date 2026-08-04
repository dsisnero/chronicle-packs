# chronicle-packs — activegraph-packs Crystal Port

Upstream: https://github.com/yoheinakajima/activegraph-packs
Revision: 6639a5385518ad49f74813373c85cf96eff9adc0 (main, pinned)
Language: python (tree-sitter inventory backend)

The upstream is the official pack library for the ActiveGraph reactive
object-graph runtime: 19 packs plus a bridge pack, importers, bundles, and a
demo server. A port is behavior-faithful when the manifest-declared surface
(object types, relation types, behaviors, tools, settings schema) and the
deterministic behaviors match upstream.

The feature roadmap below is sized from the generated inventory
(`plans/inventory/python_port_inventory.tsv`, 2080 source API items). Each
checkmark tracks the ported item count for that feature (`n/m`), where `n` is
the number of inventory items ported and `m` the total. Phases are ordered so
Core (the universal substrate) lands before the infrastructure it requires,
then communication, domain verticals, transport adapters, and the demo
surface.

**Progress: 35 / 2080 source API items ported, 1 skipped.**

## Features

### Phase 0 — Project baseline

- [x] Pack manifest format + loader — provided by the chronicle runtime
      (`Chronicle::Packs`), verified byte-exact against all 33 upstream
      manifests (`spec/chronicle_packs/vendor_manifests_spec.cr`)
- [ ] Pack scaffolding convention (`settings`, `object_types`,
      `relation_types`, `behaviors`, `tools`, `fixtures/`) — incl.
      `packs/_template` pack authoring template (0/9)
- [x] Core pack settings (`CoreSettings`) and deterministic fixture runner
      pattern (`fixtures/run_fixtures.py`) — `src/chronicle_packs/core/settings.cr`,
      `src/chronicle_packs/fixture_runner.cr`
- [ ] `packs/_preflight.py` — runtime preflight compatibility checks (0/6)

### Phase 1 — Core pack (packs/core)

- [x] 7 object types + 8 relation types — source, observation, task, action,
      artifact, memory_candidate, evaluation; grounds, produces, executes,
      generates, proposes, evaluates, derived_from, derived_from_source
      (`object_types.py` 9/9)
- [x] Behaviors `observation_extractor`, `task_linker`,
      `memory_candidate_proposer` + text-analysis helpers
      (`behaviors.py` 9/9)
- [x] Core settings `CoreSettings` (`settings.py` 1/1)
- [x] Core tools — empty (`tools.py` 1/1)
- [x] Core fixture scenarios run deterministically with no API key — all 3
      vendor scenarios pass (`fixtures/run_fixtures.py` 3/4, runner `main`
      CLI skipped)

### Phase 2 — Infrastructure packs

- [ ] `tool_gateway` — capability registry, approval policy, execute/spec/
      pending-approvals tools, catalog, standing scopes, untrusted-content
      scan (0/98)
- [ ] `secrets` — credential reference management, managed source registry
      (0/42)
- [ ] `memory_gateway` — candidate evaluation/promotion, SQLite backend,
      retrieval ranking, embedder seam (0/122)
- [ ] `identity_auth` — principal resolution, role-based access, permission
      checking (0/35)
- [ ] `agent_profile` — goals, personality, standing instructions scoped by
      channel/audience (0/32)
- [ ] `entity` — canonical extraction + dedup for people/orgs/projects/
      products/repos (0/27)
- [ ] `activity_normalizer` — provider-neutral evidence identity, replay
      modes/revisions, deterministic candidate extraction (0/87)
- [ ] `semantic_extraction` — typed source-anchored annotations, deterministic
      floor + LLM upgrade seam, coverage tracking (0/156)
- [ ] `usage` — source surfaces, connector handoffs, stable cursors,
      settlement, interaction facts (0/77)
- [ ] `connector_control` — service/account/surface status, run adapters,
      learning deltas (0/62)
- [ ] `attention` — engagement observations, bounded session batches (0/36)
- [ ] `skills` — skill lifecycle + verification/replay (0/44)
- [ ] `eval_outcome` — evaluation outcome tracking, artifact reliability
      (0/33)
- [x] `llm_provider` — provider resolution (explicit > env), deterministic
      floor, provider seam feeding the deterministic router (12/12) —
      `src/chronicle_packs/llm_provider.cr`

### Phase 3 — Communication packs

- [ ] `communication` — channel-neutral threads, messages, intents, response
      candidates (0/55)
- [ ] `chat` — sessions, memory, reply gating, agentic responses (0/56)
- [ ] `email` — threading, dedup, draft formatting, approval-gated sends
      (0/27)
- [ ] `schedule` — graph-native scheduling, ticks, heartbeats (0/35)

### Phase 4 — Domain packs

- [ ] `research` — papers, claims, hypotheses (0/35)
- [ ] `codebase` — repos, issues, PRs, architecture decisions, dependency
      auditing (0/37)
- [ ] `team_ops` — assignments, milestones, workload estimation (0/33)
- [ ] `meeting` — decision extraction, action items, summarization (0/35)
- [ ] `subject_profile` — subject-centric profile tracking (0/14)

### Phase 5 — Transport adapters and bridges

- [ ] `telegram` — inbound updates → chat_input; outbound policy-checked
      gateway sends (0/27)
- [ ] `whatsapp` — WhatsApp Cloud API transport (structural mirror of
      telegram) (0/25)
- [ ] `composio` — optional hosted Connect Links route pack (0/36)
- [ ] `gmail` — connector-conformance: profiles, replayable backfill, history
      polling, drafts, R3-forever sends (0/98)
- [ ] `mcp` — bidirectional MCP: outbound governed tools, inbound server
      (0/75)
- [ ] `evolution` — agent-authored packs behind static gates, fork trials,
      bundle-hash pins, verified owner approval (ships disabled) (0/207)
- [ ] `bridges/diligence_core` — Diligence-Core bridge mapping domain outputs
      to Core objects (0/15)

### Phase 6 — Importers (packs/importers)

- [ ] `local_files` — local directory snapshots (category local_knowledge)
      (0/26)
- [ ] `chatgpt_export` — official ChatGPT export ZIP, canonical paths +
      abandoned edit branches (0/34)
- [ ] `claude_export` — flat conversations.json (ZIP or bare) (0/34)
- [ ] `assistant_self_summary` — pasted/MCP-pushed self-summaries,
      injection-scanned (0/20)
- [ ] `assistant_local_sessions` — Claude Code + Codex session logs, bounded
      recent-N window (0/40)
- [ ] `public_presence` — gateway-routed, budgeted R0 fetch of owner public
      handles (0/40)

### Phase 7 — Bundles and demo surface

- [ ] `bundles.assistant` — core + tool_gateway + secrets + memory_gateway +
      agent_profile + identity_auth + communication + schedule + chat (0/7)
- [ ] `bundles.messaging_assistant` — assistant bundle + telegram + whatsapp
      (0/3)
- [ ] `bundles.email_assistant` — assistant bundle + email + entity (0/3)
- [ ] `bundles.research_bundle` — core + tool_gateway + memory_gateway +
      research (0/3)
- [ ] `bundles.examples` — assistant/email/research usage examples (0/3)
- [ ] `doctor` — noninteractive environment diagnostic (pass/fail, exit 0/1)
      (0/23)
- [ ] `demo_server` — HTTP API surface: /summary /graph /trace /packs /frames
      /chat /sessions /approvals /channels /reset (0/86)

### Phase 8 — Repo tooling and tests

- [ ] `scripts/generate_manifests.py` + `manifest_tools.py` — manifest
      generation and static capability extraction (0/20)
- [ ] `packs/fixtures` — cross-pack integration scenarios (chat_memory_cross_
      session, comm_chat_email_integration, l2_habit_integration, ...) (0/22)
- [ ] `tests/conftest.py` — parity test helpers (0/4)
- [ ] Upstream test porting — `plans/inventory/python_test_parity.tsv` tracks
      638 upstream tests (0/638)

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
  feature (Phase 7).

## Inventory

- `plans/inventory/python_port_inventory.tsv` — 2080 API items (tree-sitter backend)
- `plans/inventory/python_source_parity.tsv` — 2080 source API items
- `plans/inventory/python_test_parity.tsv` — 638 tests

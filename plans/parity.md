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

The remaining work is tracked in the size-graded roadmap below (S / M / L),
mirroring the `cross-language-crystal-parity` skill's feature-slicing rules:
each entry is branch-sized and user-visible, `[x]` = green and committed,
`[ ]` = pending, `[-]` = intentionally deferred (documented in the
Intentional divergences section). The `## Features` sections below remain the
per-pack detail record (surfaces, divergence notes, fixture drivers).

**Progress: 1739 / 2080 source API items ported, 17 partial, 92 skipped, 111 deferred.**
**Remaining: 120 missing items + 161/638 upstream tests ported (4 deferred).**

## Remaining feature-size roadmap (S / M / L)

### S — small (helpers, value objects, narrow surfaces)

- [x] `packs/_template` — the pack authoring template (9/9)
- [x] `packs/_preflight.py` — runtime preflight compatibility checks (6/6)
- [x] `tests/conftest.py` — parity test helpers (4/4)
- [x] `bundles.*` — bundle composition (`bundles/assistant.py` 6/7,
      `messaging_assistant` 3/3, `email_assistant` 3/3, `research_bundle`
      3/3, `bundles/examples` 3/3)
- [x] `scripts/manifest_tools.py` — static capability extraction (6/6)
- [x] Chronicle shard compatibility — update to `0b46f77` and preserve
      registration enforcement by reading runtime lifecycle events from the
      durable `EventStore` (S; 793-spec regression suite green)

### M — medium (behavioral surfaces spanning one module)

- [x] `scripts/generate_manifests.py` — manifest generation (14/14)
- [x] Importers (packs/importers) — each a self-contained ingestion surface:
    - [x] `local_files` — local directory snapshots, category local_knowledge
          (26/26)
    - [x] `assistant_self_summary` — pasted/MCP-pushed self-summaries,
          injection-scanned (20/20)
    - [x] `chatgpt_export` — official ChatGPT export ZIP, canonical paths +
          abandoned edit branches (34/34)
    - [x] `claude_export` — flat conversations.json, ZIP or bare (34/34)
    - [x] `assistant_local_sessions` — Claude Code + Codex session logs,
          bounded recent-N window (40/40)
    - [x] `public_presence` — gateway-routed, budgeted R0 fetch of owner
          public handles (40/40)
- [x] `doctor` — noninteractive environment diagnostic (pass/fail, exit
      0/1) (23/23)
- [x] `packs/fixtures` — cross-pack integration scenarios (22/22):
      `chat_memory_cross_session` (6), `l2_habit_integration` (5),
      `run_all` (4), `comm_chat_email_integration` (3),
      `identity_profile_entity_integration` (2), `cross_pack_integration` (2)

### L — large (provider/platform edges, external backends)

- [~] `evolution` — agent-authored packs under governance (70 ported, 17
      partial, 120 missing / 207):
    - [x] Crystal candidate static gatekeeper — parser-validated `pack.cr`,
          manifest identity/integrity, typed declared capability surface,
          two-way capability policy classes, require, banned-construct,
          reserved-name, size, and injection gates. Python AST/import behavior
          is an intentional language-boundary divergence, not pending work.
    - [-] Python candidate static-gate parity — intentionally not ported:
          Evolution accepts Crystal candidates only. Python `ast` extraction,
          Python imports, and Python candidate fixtures are not a contract for
          this port; see the language-boundary resolution below.
    - [ ] Crystal candidate trial, soak, and boot lifecycle — reproduce the
          vendor trial/retention guarantees for compiled Crystal candidates,
          without importing candidate source into the parent runtime.
        - [x] Trial parent orchestration — materialize and re-verify the
          gated bundle; delegate fixture then replay stages to a per-graph
          host `TrialService`; persist fixture/stage verdicts and `mod_trial`
          before transitioning to `trialed` or `rejected`. The bound service
          remains responsible for the isolated compiled child, allow-listed
          environment, resource limits, persisted fork, and durable replay
          evidence; there is deliberately no in-process Crystal fallback.
        - [x] Durable trial-fork reload — reopen an existing SQLite fork from
          its recorded run id for review/promotion evidence only. Reloaded
          forks deliberately carry no parent pack registrations; absent,
          retired, empty, or unreadable runs fail closed as unavailable.
        - [x] Trial-fork retention housekeeping — retain forks for adoptable
          proposals, archive only labeled disposable trial/fixture-gate forks,
          and honor Chronicle's unconditional provenance and lineage pins.
        - [x] Boot promotion-record reconciliation — marker-proven loading
          records heal and close their open ticket; ambiguous records park;
          duplicate active records resolve by recency with durable boot-heal
          gaps. Candidate activation itself remains host-bound.
        - [x] Boot recency parking — a newer disabled promotion keeps an
          older active record down, while a newest disabled record stays down;
          the parent records the durable outcome without executing candidates.
        - [x] Boot sealed-pack reload — active promotion records re-verify
          their bundle and reload only through the bound host service; missing
          services, proposals, or mismatched sealed packs fail closed.
    - [x] Verified Crystal candidate materialization — reassemble proposal
          artifacts, write a fresh candidate tree, and verify its external
          bundle pin without loading or executing it.
    - [x] Promotion rollback and supersession reconciliation — process
          governed disable tickets idempotently, record durable rollbacks,
          and preserve one active promotion per pack name.
    - [~] Candidate activation — phase-two adoption with Crystal loading and
          persisted fork promotion.
        - [x] Adoption preflight — between-frame ticket processing re-verifies
          the reviewed bundle, re-runs static/injection gates, requires the
          latest durable passing fork, and rejects promotion conflicts before
          any host-bound candidate activation.
        - [x] Host-bound activation and promotion — a per-graph host service
          maps a re-verified tree to a sealed compiled pack; the parent then
          records loading, promotes the persisted fork, settles active, and
          supersedes older active records. Host service provisioning and boot
          reload activation remain separate integration work.
    - [ ] Crystal author and deterministic scenarios — a keyless Crig-backed
          drafting seam plus Crystal candidate fixtures; Python author source
          and fixture modules are references, not runtime dependencies.
        - [x] Keyless author source contract — a host author receives pure
          data and may return only the four Crystal source bodies; pack-owned
          identity, manifests, provenance, fixtures, and activation remain
          outside the model boundary.
        - [x] Keyless author service binding — each graph dispatches pure
          frames only to its explicitly host-bound author service and refuses
          when none is configured; dispatch still cannot create proposals or
          load candidate code.
        - [x] Deterministic author-frame assembly — construct the pure
          four-section frame from the charter, charset-validated gap evidence,
          `pack.loaded` surface, and envelope-wrapped verified-owner text;
          retain only admitted ids and recomputed injection flags for later
          sealing and submission.
      See the `evolution` divergence note for the exact boundary between the
      Crystal candidate path and missing Python-specific behavior.
- [x] `demo_server` — HTTP API surface: /summary /graph /trace /packs
      /frames /chat /sessions /approvals /channels /reset (72/86; 14
      deferred: SQLite persist/resume, MCP outbound, managed OAuth,
      schedule tick driver, demo capability registration helper)

### Separate tracking

- [~] Upstream test porting — `plans/inventory/python_test_parity.tsv`
      tracks 638 upstream tests (86/638; test_approval_auth, test_preflight,
      test_llm_provider, test_manifests, test_schedule_pack,
      test_web_fetch_capability, test_capability_catalog,
      test_registration_check, test_llm_tool_proxies,
      test_attention_vectors, test_eval_outcome, test_skills,
      test_usage, test_activity_normalizer, test_injection_posture
      ported; stub-injection cases deferred)

### Next up (concrete plan order)

1. `[ ]` `evolution` Crystal candidate trial, soak, and boot lifecycle.
2. `[ ]` `evolution` candidate activation.
3. `[ ]` `evolution` Crystal author and deterministic scenarios.
4. `[ ]` Upstream test porting (638 tests), tracked separately (161/638).

### Evolution candidate-language resolution

Evolution is a **Crystal-candidate-only** feature in this port. The pinned
Python implementation is normative for governance outcomes and failure
posture, but it does not require this project to accept, import, execute, or
generate Python candidate packs.

- **Static gates:** the Crystal compiler parser and manifest-derived surface
  extraction replace Python `ast` inspection. A successful Crystal compile is
  useful evidence that a candidate is buildable in a pinned environment, but
  it is not sufficient for admission: it does not prove the reviewed bundle
  pin, manifest/source surface agreement, allow-listed dependencies, reserved
  namespace policy, injection posture, fixture behavior, or runtime safety.
  Static gates remain required before any candidate compilation.
- **Execution and activation:** Crystal does not safely `require` an
  agent-authored source tree at runtime. The pending Crystal trial/activation
  design must compile a verified, pinned candidate in an isolated child and
  run its fixtures/replay there with an allow-listed environment, resource and
  wall-clock limits, and a persisted fork. The parent runtime reads only the
  durable verdict/delta, then promotes it after approval. A host-process
  `crystal build`, a parser pass, or a dynamic source load does not satisfy
  this boundary.
- **Python-specific mechanics:** `ast`, `importlib`, Python module decorators,
  and `fixtures/run_fixtures.py` are intentionally not ported as runtime
  dependencies. Their vendor tests define the behavior that equivalent Crystal
  parsing, manifests, annotations, child scenarios, and audit records must
  demonstrate.
- **Authoring:** any future author returns constrained Crystal source bodies
  through the existing governed/recorded seams; pack identity, manifest,
  hashes, provenance, and fixtures remain deterministic code-owned output.
  A Python author or a Python interpreter is neither needed nor accepted.

## Features

### Phase 0 — Project baseline

- [x] Pack manifest format + loader — provided by the chronicle runtime
      (`Chronicle::Packs`), verified byte-exact against all 33 upstream
      manifests (`spec/chronicle_packs/vendor_manifests_spec.cr`)
- [x] Pack scaffolding convention (`settings`, `object_types`,
      `relation_types`, `behaviors`, `tools`, `fixtures/`) — incl.
      `packs/_template` pack authoring template (9/9)
- [x] Core pack settings (`CoreSettings`) and deterministic fixture runner
      pattern (`fixtures/run_fixtures.py`) — `src/chronicle_packs/core/settings.cr`,
      `src/chronicle_packs/fixture_runner.cr`
- [x] `packs/_preflight.py` — runtime preflight compatibility checks (6/6)

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

- [x] `tool_gateway` — capability registry, approval policy, execute/spec/
      pending-approvals tools, catalog, standing scopes, untrusted-content
      scan (90/98: object surface + registry + sanitizer + injection
      scan + policy decision + approval resolution + 4 core behaviors + the
      capability catalog + registration enforcement + ADR 0018 standing
      scopes (propose/promote/demote/disable + the R2 auto-approval read
      path) + the tool_policy_reliability_guard behavior + the integration
      profile chassis (aggregator/profile/exploration receipts, stable ids
      and shape fingerprints) + the reference web.fetch_url capability
      (host seam, fails closed) + LLM tool proxies (CrigGatewayTool as a
      Crig::ToolDyn: audit-before-action capability_call, shared
      decide_policy/execute_approved_call, held calls return structured
      held_for_approval; Crig supplies the tool transport only); the 8
      skipped items are fixture-runner CLI helpers + `_StrictModel`)
- [x] `secrets` — credential reference management, managed source registry
      (42/42) — `src/chronicle_packs/secrets/`
- [~] `memory_gateway` — candidate evaluation/promotion, SQLite backend,
      retrieval ranking, embedder seam (66/122, slices 1-2: graph-backed
      lifecycle — candidate_evaluator/memory_writer/memory_retriever/
      memory_ranker/memory_reliability_applier, lexical_score, retrieve_
      memories, resolve_memory_query (evidence-authoritative), the
      EmbeddingService boundary (HashEmbedder/OpenAIEmbedder,
      default_embedder_factory, per-graph recorded service with
      embedding.requested/responded + idempotency replay, space-aware
      cosine blend stored on memory_item), and versioned promotion
      (propose/resolve with memory.promoted/memory.demoted,
      memory_promotion_proposer behavior, verify_memory_replay_fn);
      SQLite/adapters deferred)
- [x] `identity_auth` — principal resolution, role-based access, permission
      checking (35/35) — `src/chronicle_packs/identity_auth/`
- [x] `agent_profile` — goals, personality, standing instructions scoped by
      channel/audience (32/32) — `src/chronicle_packs/agent_profile/`
- [x] `entity` — canonical extraction + dedup for people/orgs/projects/
      products/repos (27/27) — `src/chronicle_packs/entity/`
- [x] `activity_normalizer` — provider-neutral evidence identity, replay
      modes/revisions, deterministic candidate extraction (71/87) —
      `src/chronicle_packs/activity_normalizer/` (ADR 0026 annotation layer,
      shared-extraction selection/migration, and the structure-candidate
      projector now complete)
- [~] `semantic_extraction` — typed source-anchored annotations, deterministic
      floor + LLM upgrade seam, coverage tracking (108/156, slices 1-2c: the
      deterministic zero-key floor (DeterministicExtractorV1) + facets +
      seeded extraction_profile (incl. the D025 LLM-upgrade branch routing
      event/relation_mention to semantic.llm when a provider is configured)
      + the eager annotate pipeline with cache idempotency + the
      profile/memory candidate projectors + the profile-update/
      extractor-invalidation tools + extract_selected_evidence (exact-span
      requests settle with run_ids/annotation_ids; evidence/revision
      verified, spans hash-verified and remapped by the pack) + the guarded
      proceduralization lifecycle (RequestRuleExtractorV1,
      synthesize/evaluate/promote, guard_admits + shape fingerprint,
      active_procedure_for, record_deoptimization with drift auto-demote;
      evaluation is graph-direct, no runtime fork) + the
      synthesize_request_procedure / promote_request_procedure tools + the
      ADR 0014 fork-trial-promote surface (run_extractor_trial_fn
      drafts-only comparison keyed by facet/start/end/exact,
      promote_llm_extractor_fn routing the covered facets) +
      ensure_llm_extraction_profile_fn (mints a policy version routing the
      model-only facets after an explicit provider configuration) + the
      LLMExtractorV1 adapter (semantic.llm@0.1.0 behind the registry:
      byte-exact anchor verification, facet-body shaping, per-facet caps,
      prompt-hash idempotency, riding a RecordedCompletion boundary with
      llm.requested/responded + replay);
      fixture generators remain deferred)
- [x] `usage` — source surfaces, connector handoffs, stable cursors,
      settlement, interaction facts (71/77) — `src/chronicle_packs/usage/`
- [x] `connector_control` — service/account/surface status, run adapters,
      learning deltas (59/62) — `src/chronicle_packs/connector_control/`
- [x] `attention` — engagement observations, bounded session batches (36/36)
      — `src/chronicle_packs/attention/`
- [x] `skills` — skill lifecycle + verification/replay (43/44, 1 deferred)
      — `src/chronicle_packs/skills/`
- [x] `eval_outcome` — evaluation outcome tracking, artifact reliability
      (33/33) — `src/chronicle_packs/eval_outcome/`
- [x] `llm_provider` — provider resolution (explicit > env), deterministic
      floor, provider seam feeding the deterministic router (12/12) —
      `src/chronicle_packs/llm_provider.cr`

### Phase 3 — Communication packs

- [x] `communication` — channel-neutral threads, messages, intents, response
      candidates (55/55)
- [x] `chat` — sessions, memory, reply gating, agentic responses (56/56)
- [x] `email` — threading, dedup, draft formatting, approval-gated sends
      (27/27)
- [x] `schedule` — graph-native scheduling, ticks, heartbeats (35/35)

### Phase 4 — Domain packs

- [x] `research` — papers, claims, hypotheses (35/35)
- [x] `codebase` — repos, issues, PRs, architecture decisions, dependency
      auditing (37/37)
- [x] `team_ops` — assignments, milestones, workload estimation (33/33)
- [x] `meeting` — decision extraction, action items, summarization (35/35)
- [x] `subject_profile` — subject-centric profile tracking (14/14)

### Phase 5 — Transport adapters and bridges

- [x] `telegram` — inbound updates → chat_input; outbound policy-checked
      gateway sends (27/27)
- [x] `whatsapp` — WhatsApp Cloud API transport (structural mirror of
      telegram) (25/25)
- [x] `composio` — optional hosted Connect Links route pack (36/36)
- [x] `gmail` — connector-conformance: profiles, replayable backfill, history
      polling, drafts, R3-forever sends (96/98, 1 skipped + 1 deferred)
      — `src/chronicle_packs/gmail/` (see the `gmail` divergence note)
- [x] `mcp` — bidirectional MCP: outbound governed tools, inbound server
      (74/75, 1 skipped) — `src/chronicle_packs/mcp/` (see the `mcp`
      divergence note)
- [~] `evolution` — agent-authored packs behind static gates, fork trials,
      bundle-hash pins, verified owner approval (ships disabled) (68 ported,
      15 partial, 124 missing / 207:
      slices 1-3 port the deterministic graph-native surface — 8 object
      types + 5 relation types, EvolutionSettings (ships disabled),
      author_frame (charter pin + structured-field charset + taint
      recompute), materialize's portable file/hash helpers, the
      authoring/request tools (submit_proposal / open_reflection_gap /
      request_adoption), the graph-native behaviors (gap_detector,
      proposal_gatekeeper's taint-suspension and Crystal static-gate paths,
      promotion_recorder,
      watch_monitor), the trial-driver render, adopt registration with its
      two refusals, and the full review decision surface (build_review +
      render_review_html + render_approvals_index_html, unified diff via
      the `similar` shard). The remaining 139 items are tracked in the
      size-graded roadmap, L: `evolution` — see the `evolution` divergence
      note for what is deferred vs. ported)
- [x] `bridges/diligence_core` — Diligence-Core bridge mapping domain outputs
      to Core objects (15/15) — `src/chronicle_packs/bridges/` (see the
      `bridges/diligence_core` divergence note)

### Phase 6 — Importers (packs/importers)

All six importers are ported: `local_files` (26/26),
`assistant_self_summary` (20/20), `chatgpt_export` (34/34),
`claude_export` (34/34), `assistant_local_sessions` (40/40),
`public_presence` (40/40).

### Phase 7 — Bundles and demo surface

- `bundles.*` (18/19; `_chat_pack_for` deferred) — `bundles.assistant`
  (6/7), `messaging_assistant` (3/3), `email_assistant` (3/3),
  `research_bundle` (3/3), `bundles.examples` (3/3) — ported into
  `Chronicle::Packs::Bundles` (`src/chronicle_packs/bundles.cr`), driven
  in-process by `spec/chronicle_packs/bundles_spec.cr`. Tracked in the
  size-graded roadmap, S: `bundles.*`.
- `doctor` — noninteractive environment diagnostic (pass/fail, exit 0/1)
  (23/23) — ported into `Chronicle::Packs::Doctor`
  (`src/chronicle_packs/doctor.cr`), driven by
  `spec/chronicle_packs/doctor_spec.cr`. Tracked in the size-graded
  roadmap, M: `doctor`.
- `demo_server` — HTTP API surface: /summary /graph /trace /packs /frames
  /chat /sessions /approvals /channels /reset (72/86) — ported into
  `Chronicle::Packs::DemoServer` (`src/chronicle_packs/demo_server.cr`),
  driven by `spec/chronicle_packs/demo_server_spec.cr`. Tracked in the
  size-graded roadmap, L: `demo_server`.

### Phase 8 — Repo tooling and tests

- `scripts/generate_manifests.py` (14) + `manifest_tools.py` (6) — manifest
  generation and static capability extraction (20/20) — ported into
  `Chronicle::Packs::ManifestTools` + `Chronicle::Packs::ManifestGenerator`
  (see the `scripts` divergence note).
- `packs/fixtures` — cross-pack integration scenarios (chat_memory_cross_
  session, comm_chat_email_integration, l2_habit_integration, ...) (22/22) —
  ported into `Chronicle::Packs::Fixtures`
  (`src/chronicle_packs/fixtures.cr`), driven in-process by
  `spec/chronicle_packs/fixtures_spec.cr`. Tracked in the size-graded
  roadmap, M: `packs/fixtures`.
- `tests/conftest.py` — parity test helpers (4/4) — ported into
  `Chronicle::Packs::Conftest` in `spec/spec_helper.cr` (see the
  `_preflight`/`_template`/`conftest` divergence note).
- Upstream test porting — `plans/inventory/python_test_parity.tsv` tracks
  638 upstream tests (161/638, 4 deferred). Tracked separately in the
  size-graded roadmap.

## Intentional divergences

- Registration enforcement (`packs/tool_gateway/registration_check.py`) reads
  `graph.events`, which upstream populates with runtime-emitted `pack.loaded`
  / `pack.disabled` events. In Chronicle `0b46f77`, runtime lifecycle events
  are owned by `Runtime#store`; `GraphProjection#events` contains only events
  emitted through the projection. The port therefore arms enforcement with
  the runtime's durable `EventStore` and scans `store.iter_events`, retaining
  `graph.events` as the fallback for direct graph-emission fixtures. The ported
  `tool_gateway` pack now declares `catalog.search` and `web.fetch_url` as
  `CapabilityDecl`s (matching the vendor manifest's `[[surface.capabilities]]`
  and the upstream `__init__.py`) so armed registration recognizes the
  gateway's own boot registrations.
- Upstream test porting (`plans/inventory/python_test_parity.tsv`) maps
  upstream tests to in-process Crystal specs over the ported surface.
  `test_approval_auth.py` is ported via
  `spec/chronicle_packs/demo_server_spec.cr::check_approval_auth` — the
  ported `check_approval_auth` takes the graph and audits refusals as
  `approval_auth_denial` objects exactly like upstream. `test_preflight.py`
  is ported via `spec/chronicle_packs/preflight_spec.cr`; the verbatim
  too-old message and the version-embedding variants are pinned, and the
  stub-module injection tests (`_stub_runtime`/`_OldCapabilityDecl`/
  `_NewCapabilityDecl`) are deferred because the port's runtime feature
  detection is compile-time (chronicle compiled in) — there is no Python
  module to inject.
- `demo_server` is ported into `Chronicle::Packs::DemoServer`
  (`src/chronicle_packs/demo_server.cr`). The HTTP REST surface and the
  Handler dispatch are kept; `main` binds a real `HTTP::Server` (port 7788
  or `ACTIVEGRAPH_PORT`), while specs drive the `Handler` dispatch
  in-process (the port's analog of upstream's `_RuntimeExecutor`). The
  runtime is built with `Bundles.build_assistant` over a memory store with
  `seed_profile: false` (upstream persists to a SQLite event-log file and
  resumes via `Runtime.load`, and seeds no default profile) — the endpoint
  surface is unchanged. Endpoints needing deferred seams return the same
  shapes with a clear message: `/mcp` 503 (no MCP gateway), OAuth start/poll
  501 (managed OAuth source), and the schedule tick driver, `_store_has_run`
  /`_wipe_store`/`_db_path`/`_memory_db_path`/`_token_db_path`,
  `_register_demo_capabilities` (partial gateway capability registration),
  and `_ensure_provider_credential_refs` are deferred. `check_approval_auth`
  uses `Crypto::Subtle.constant_time_compare`. GET /capabilities reads the
  ToolGateway `LocalRegistry`; GET /packs enumerates `Registry.discover`.
- `packs/fixtures` is ported into `Chronicle::Packs::Fixtures`
  (`src/chronicle_packs/fixtures.cr`). Each scenario runs in-process against
  a fresh store/graph/runtime with a deterministic mock completion model
  (`FixtureModel`) — no LLM, no API key, no subprocess. The upstream
  `main` CLIs are driven by `spec/chronicle_packs/fixtures_spec.cr`, and
  `run_all.py`'s subprocess runner becomes `Fixtures.main`/`_run_fixture`
  running every scenario in-process (exit 0/1; `io` seam for tests).
  `chat_memory_cross_session` persists the event log to a SQLite event store
  file and replays it into a fresh graph via `Runtime.load` for session 2
  (the port's memory gateway is graph-backed; upstream uses a separate
  SQLite memory backend file — recall still crosses the session boundary).
  `cross_pack_integration` wires the ToolGateway `credential_resolver` seam
  to the Secrets `resolve_and_audit_fn` so the credential audit trail
  (use_count bump) matches upstream. `l2_habit_integration` mints the
  skill_candidate via the activity_normalizer legacy direct-write path
  (`legacy_extraction_enabled: true`) because the port's zero-key
  `semantic.deterministic` extractor only covers `communication` facets (the
  upstream annotation-first shared-extraction layer needs the LLM extractor);
  the skill object and its lifecycle are unchanged.
- `doctor` is ported into `Chronicle::Packs::Doctor`. The eight-check
  contract (name/status/detail), the injectable-inputs discipline, the
  exit code (0 = no failures, skips fine), and `--json` output are kept.
  Adaptations: `check_python_version` is renamed `check_crystal_version`
  (report name "crystal-version") and checks `Crystal::VERSION` against
  `CRYSTAL_FLOOR` (shard.yml `crystal: '>= 1.21.0'`) instead of a Python
  floor; `check_package_shadowing` live-probes nothing (the chronicle
  runtime is linked into a compiled binary — no import path to shadow) so
  the live default SKIPs while the injectable decision logic
  (origin/namespace_locations/installed_roots) is ported and tested;
  `check_entry_points` live-probes `Chronicle::Packs::Registry.discover`
  (registered packs) instead of Python importlib entry points;
  `check_manifest_hash` defaults repo_root to this checkout and live SKIPs
  (no `packs/` tree with committed generated manifests); `check_llm_provider`
  resolves through the ported `LLMProvider` and its `--live` ping is an
  injectable `live_ping` proc because the pack owns no live provider client
  (the default `_default_live_ping` raises a clear `PackError`).
  `_installed_activegraph_roots`/`_site_dirs` are deferred (Python pip/site
  introspection; no Crystal analog).
- `bundles.*` is ported into `Chronicle::Packs::Bundles`
  (`src/chronicle_packs/bundles.cr`). Bundles are composition helpers, not
  manifest packs: upstream builds a list of `Pack` objects and registers
  them on a Runtime; the port `load_pack`s each pack directly. The runtime
  is `Chronicle::Runtime(BundleModel)` (a Crig completion mock); the
  `load_*`/`seed_*` helpers are generic `forall M` so specs can drive them
  over the shared `Runtime(PackModel)`. `build_assistant` clears the
  in-process `principal_registry` on entry so it is a correct standalone
  factory (upstream has no such registry). `build_email_assistant` returns
  the same `{store, graph, rt}` triple as the other builders. The bundle
  example scripts' `main` functions are driven in-process by
  `spec/chronicle_packs/bundles_spec.cr` (no subprocess entrypoints).
  `build_assistant`'s `_chat_pack_for` seam (rebuilding the chat pack with an
  agentic responder when `llm_tools` are passed) is deferred: the ported
  chat pack has no `build_chat_pack` re-construction seam, so
  `build_assistant` registers the default (non-agentic) chat pack.
- `packs/importers/public_presence` is ported. It is the first importer with
  a governed-capability flow: `bootstrap_public_presence_fn` only PROPOSES
  `capability_call` objects (status proposed, R0/low, carrying the
  `public_presence` metadata); the Tool Gateway's policy_enforcer (R0
  auto-approves) and call_executor own approval/execution, and the
  `acquire_presence_result` behavior lands executed results as
  injection-scanned, replay-retained evidence. The pack declares
  `presence_bootstrap_run` (+ `bootstrap_call` relation) and the
  `public_presence.fetch_page` capability (R0). The fetch handler routes
  through the ToolGateway `web_fetch_fetcher` host seam (fails closed
  without a fetcher); the deterministic specs register a stub. `html_to_text`
  is a minimal stdlib tokenizer (upstream uses `html.parser`). Porting
  surfaced a gateway bug: `execute_approved_call` built CapabilityResult
  with `success: ... || true`, which turned explicit handler failures into
  `success: true`; fixed to `!= false` so `fetch_failed` is recorded. Same
  divergence family as the other importers: `PackError` for validation, the
  host-bound `PublicPresence.bound_graph` tool seam.
- `packs/importers/assistant_local_sessions` is ported. It imports both the
  Claude Code `projects/` layout (ordered by file mtime with a
  relative-filename tiebreak) and the Codex `sessions/` layout (ordered by
  the `rollout-<timestamp>-<uuid>.jsonl` filename timestamp), keeping the
  most recent `max_sessions` files in the returned window log. Parsers are
  deliberately defensive: a JSONL line either yields one user/assistant
  message unit (Claude text parts; Codex `input_text`/`output_text`/`text`
  parts, nested `response_item`/`payload.message` + flat `message`
  variants) or is skipped and counted. A non-UTF-8 file records a
  recoverable `unreadable_file` failure (Crystal's `String.new(Bytes)`
  substitutes invalid bytes, so `valid_encoding?` is checked explicitly);
  malformed lines are counted, never fatal. `_provider_time` validates
  ISO-8601. Same divergence family as the other importers: `PackError` for
  unsupported provider/replay_mode/missing surface, host-bound
  `AssistantLocalSessions.bound_graph` tool seam. The window is built fresh
  in `_result` from the final `files_imported`/`files_failed` arrays.
- `packs/importers/claude_export` is ported as the structural mirror of
  `chatgpt_export` with a flat conversation list (no branch tree): every
  `chat_messages` message becomes one acquired-item/content pair. The
  export is accepted as the official ZIP or a bare conversations.json
  snapshot, detected by extension and the `PK\x03\x04` magic bytes (read as
  a little-endian UInt32). `_normalized_message` prefers typed content
  blocks and omits non-text kinds (`[tool_use content omitted]`); sender
  `human`/`assistant` map to `role` `user`/`assistant`. Same divergence
  family as `chatgpt_export`: `ExportFormatError` is an `Exception`
  subclass, unsupported modes/surface raise `PackError`, and the tool uses
  the host-bound `ClaudeExport.bound_graph` seam.
- `packs/importers/chatgpt_export` is ported. It reads the export ZIP with
  the Crystal stdlib `Compress::Zip` reader (upstream `zipfile`) and parses
  conversations.json as a tree: the path ending at the provider's
  `current_node` is canonical, other message nodes are abandoned branches
  (`correction_signal`, `nearest_canonical_ancestor_id`). `ExportFormatError`
  is an `Exception` subclass (upstream `ValueError`); unsupported
  replay_mode / missing source_surface_id raise `PackError`, and the tool
  uses the host-bound `ChatGPTExport.bound_graph` seam. `_provider_time`
  renders numeric epoch seconds with `%:z` (matching Python's isoformat
  offset). Node identity/parent-chain validation is faithful (cycle
  detection, declared-id mismatch, missing parent).
- `packs/importers/assistant_self_summary` is ported. It follows the same
  edge-adapter shape as `local_files`: `acquired_item` +
  `acquired_content` handoffs to Activity Normalizer, empty object/
  relation/behavior surfaces, and the `import_assistant_self_summary` tool
  on the host-bound `AssistantSelfSummary.bound_graph` seam. Identity is
  the canonical content hash (`self_summary:<sha256>` dedup key), so the
  same summary pasted (`manual`) or pushed (`mcp`) lands on one evidence
  identity with `connection_path` recording the transport. Injection
  scan flags land in `normalized_metadata` (hostile text stays inert:
  evidence → annotations → candidates, nothing that acts). Unsupported
  transports raise `PackError` (upstream `ValueError`). The tool raises
  `PackError` where upstream raises `ValueError` (empty/oversized summaries
  instead return failure records, matching upstream's return-shape).
- `packs/importers/local_files` is ported. The importer's `json_root_type`
  normalized-metadata field records the JSON root's structural kind in the
  JSON spec's language-neutral vocabulary (`object`/`array`/`string`/
  `number`/`boolean`/`null`) instead of upstream's Python
  `type(parsed).__name__` — the field is informational metadata only
  (nothing consumes it, no upstream test/fixture asserts it, and it is not
  part of the manifest surface), so it stays meaningful for any host
  (Crystal, Ruby/mruby, ...). The `import_local_files` tool uses the
  host-bound `LocalFiles.bound_graph` seam (chronicle's Tool model is
  args-only) and raises `PackError` where upstream raises `ValueError`
  (unsupported replay_mode, missing source_surface_id). File-read failures
  are flagged recoverable on `IO::Error` (upstream `OSError`); malformed
  JSON on a `.json` file records `invalid_json`.
- `scripts/generate_manifests.py` + `scripts/manifest_tools.py` are ported
  into `Chronicle::Packs::ManifestTools` (pure TOML quoting + the
  `# requires=`/`integrates_with=` docstring reader) and
  `Chronicle::Packs::ManifestGenerator` (`PACK_PATHS` name→dir mapping,
  `generate` writing a manifest.toml whose content hash is
  `compute_content_hash` over the pack's Crystal source directory). The
  upstream `extract_capability_registrations`/`extract_consumed_capabilities`
  parse Python AST for `register_local_capability`/`capability_call`
  literals; in the Crystal port the DSL already collected the declared
  surface and `[[surface.capabilities]]` at compile time, so the extraction
  seam is the live `Chronicle::Packs::Pack` object (`Pack.capabilities` →
  CapabilityDecl-shaped rows; `consumes` = declared capability keys). The
  dependency convention is read from the Crystal `pack.cr` text (the port
  analog of upstream's Python `__init__.py`); `_param_default`/`_resolve`/
  `_literal`/`_iter_pack_sources` have no separate Crystal equivalent — the
  live-Pack seam subsumes their job.
- `packs/_template`, `packs/_preflight.py`, and `tests/conftest.py` are
  ported as the S bucket. The template has no real upstream manifest (its
  manifest.toml is a skeleton with a REGENERATE-ME hash), so its surface
  is verified against the upstream `__init__`/`object_types`/`behaviors`/
  `settings` declarations rather than a pinned manifest hash; the fixture
  scripts are driven by `spec/chronicle_packs/template_spec.cr`. The
  preflight's `RuntimePreflightError` is an `Exception` subclass (Crystal
  has no `ImportError`), and `runtime_supports_contract` feature-detects
  chronicle's `CapabilityDecl.action_class` at compile time (the "runtime"
  is the compiled-in chronicle shard, so `found_runtime_version` reads
  `Chronicle::VERSION`). The conftest helpers live as
  `Chronicle::Packs::Conftest` in `spec/spec_helper.cr`: the hermetic
  `hermetic_environment` deletes the ambient LLM keys and clears the
  resolved LLM provider + composio transport, and `assert_fixture_passed`
  raises `PackError` with stdout/stderr tails (fixtures run in-process via
  specs rather than as subprocesses).
- Chronicle is pinned to the latest `dsisnero/chronicle` main
  (`0b46f77`), which provides `Runtime#fork`/`promote`/`disable_pack` and
  `Runtime#errors` (BehaviorFailure projection); the older locked commit
  lacked them and the working tree relied on a newer checkout that
  `shards install` had clobbered. `similar` (dsisnero/similar.cr) is a
  declared dependency for the review decision surface's unified diff.
- The manifest loader/validator/hashing lives in the chronicle runtime
  shard (`Chronicle::Packs`), not in this repo — upstream owns it in
  `activegraph.packs.manifest`; chronicle ports it. This repo verifies it
  against the real upstream manifests.
- Manifest spec conformance: `vendor/activegraph-packs/docs/manifest-spec.md`
  (FROZEN) is language-agnostic (TOML schema, two-way surface contract,
  byte hash) and is unchanged by the port. `Chronicle::Packs` is the
  Crystal reference implementation of its §9 runtime half
  (`load_manifest` / `verify_surface` / `compute_content_hash` /
  `compute_bundle_hash`), with the Crystal-side mappings the spec's
  identity table implies (e.g. `settings_schema` is the settings class
  name string, `Pack.capabilities` is `Array(CapabilityDecl)`). Byte-exact
  §4 hash parity is proven by every upstream pack's pinned `content_hash`
  recomputing identically (`spec/chronicle_packs/vendor_manifests_spec.cr`).
  The port never regenerates upstream manifests, so the Python-specific
  `[dependencies]`/`fixtures` fields stay as-is.
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
- `identity_auth` tool results are typed `JSON::Serializable` structs
  (`PermissionCheck`, `PrincipalRegistration`). The declared tools are
  `@[Tool]` wrappers over the `*_fn` functions and require a graph bound
  by the host (`IdentityAuth.bound_graph`) because chronicle's Tool model
  is args-only (no graph injection); the `*_fn` functions take the graph
  explicitly and are fully testable. `Principal.is_owner`/`is_external`/
  `can` are renamed to Crystal predicates `owner?`/`external?`/`can?`;
  the tool wrapper methods use a `_tool` suffix. `principal_entity_linker`
  is a no-op until the entity pack is ported (upstream also no-ops without
  it). chronicle's `patch_object` replaces data, so the pack merges fields
  manually (upstream merges).
- `agent_profile` assembles context views as a typed `ProfileContextView`
  struct; the pure assembly function is public `build_profile_context_view`
  (upstream `_build_profile_context_view`) so both the provider behavior and
  `assemble_profile_view` share one definition. Tools follow the same
  host-bound-graph seam and `_tool` suffix as identity_auth. Goal priority
  order lives in a nested `GoalPriorities::ORDER` constant (the DSL pack
  macro assumes direct module constants are types).
- `entity` uses typed value objects: `MentionCandidate` and
  `EntityRegistryEntry` are `struct`s with `JSON::Serializable` (the
  mention candidate serializes straight to the graph; the registry entry
  mirrors entity data), and `SimilarityResult` is a struct. The shared
  similarity helpers are public (`edit_distance_ratio`,
  `identifier_overlap_score`, `compute_similarity`) —
  `identifier_overlap_score` is the seam identity_auth's
  `principal_entity_linker` will use once wired. The extraction regexes
  live in a nested `Extraction` module (the DSL pack macro assumes direct
  module constants are types).
- `secrets` keeps the CRITICAL INVARIANT (names only, never values): the
  resolved value is returned to the caller and never touches the graph,
  events, or logs. The managed OAuth source (`OAuthTokenStore` is SQLite
  via crystal-db, `OAuthDeviceFlow` takes an injectable `http_post` so the
  flow runs offline) lives in `Chronicle::Packs::Secrets::Managed`.
  `OAuthDeviceFlow` is a `struct`; `OAuthCredentialSource` is a class (its
  `flows` map mutates via `add_flow`). The `resolve_credential` tool is
  pure (no graph seam needed).
- `attention` projects explainable importance/source-trust vectors from
  signals and canonical outcome events, with all four object types as
  `JSON::Serializable` structs (explicit `initialize`; getter defaults
  keep partial JSON valid). The signal-capture and trust behaviors fire on
  custom event types (`attention.signal_observed`, `outcome.*`) driven via
  `graph.emit`. The Pydantic `_StrictModel` `extra="forbid"` is not
  enforced (JSON::Serializable ignores unknown fields). `_objects` is
  absorbed into `graph.objects` calls; `_stable_id` shares `_stable_key`.
- `skills` models every typed node as a `JSON::Serializable` struct:
  `OutcomeSummary`, `PromotionHistoryEntry` (for `skill.promotion_history`,
  replacing loose hashes), and the four object types. The lifecycle
  (author/invoke/evidence/promote/demote/disable) is deterministic and
  emits `skill.proposed`/`skill.used`/`skill.promoted`/`skill.demoted`
  events; tools use the host-bound graph seam with `_tool`-suffixed
  wrappers. `verify_skill_replay_fn` is DEFERRED — the fork-trial re-run
  is pending; chronicle now provides `Runtime#fork` (bumped to `0b46f77`),
  so the fork-based replay step can land with it. The portable replay
  pieces (`SkillReplayIncompleteError`, `_recorded_usage`, `_lineage_gaps`)
  are ported.
- `eval_outcome` models its nodes as `JSON::Serializable` structs:
  `OutcomeRecord`, `ArtifactReliability`, and the nested `ReliabilityTallies`.
  Outcome capture emits canonical `outcome.*` events that the
  `artifact_reliability_projector` folds into a typed, evidence-explainable
  reliability projection (emitting `reliability.changed`, which the skills
  pack's eligibility behavior consumes). Terminal outcomes are exclusive
  (correction requires supersession); maintenance outcomes are idempotent
  by contribution key. The upstream fixture also loads memory_gateway; the
  behavior/tool specs run without it.
- `communication` declares the full manifest surface (9 object types, 12
  relation types, 7 behaviors, 3 tools, `CommunicationSettings`). Every
  module-level string/array/hash/alias constant is nested
  (`HygienePatterns`, `GateConstants`, `Intents`, `FamilyConstants`) because
  the DSL pack macro assumes direct module constants are types. The legacy
  comm_* behaviors and conversation-family projectors use typed structs with
  `copy_with`; `_merge_patch`/`_patch` merge explicitly (chronicle's
  `patch_object` replaces data, upstream merges). Relation processor
  source/target types match how the ported behaviors write relations
  (e.g. `intent_of` is `comm_intent → comm_message`; `fulfills_intent` is
  `capability_call → comm_intent`). Tools use the host-bound graph seam and
  `_tool` suffix as identity_auth. The upstream reply-gating bundle
  (`test_reply_gating.py`) depends on the chat pack; the gate itself is
  ported and covered directly via `decide_reply` + identity_auth
  `register_principal_fn`. `_find` is replaced by `_index_objects`. Fixture
  scripts are driven by `spec/chronicle_packs/communication_spec.cr`.
- `chat` declares the full manifest surface (5 object types, 3 relation
  types, 8 behaviors, 2 tools, `ChatSettings`). `chat_ingester` translates
  `chat_input` → `CommMessage` (channel=chat) + `ChatSession` + `ChatTurn`;
  conversation memory is graph-native — `chat_context_assembler`
  reconstructs prior turns from persisted `chat_turn` objects (bounded by
  `max_context_messages`), so context survives an API-server restart with no
  in-process history (the per-session caches are convenience only, with
  graph fallback). The provider classes in upstream `llm.py`
  (`MockChatProvider`, `FallbackChatProvider`, `select_chat_provider`,
  `resolve_chat_config`) live on the runtime LLM seam
  (`src/chronicle_packs/llm_provider.cr`); the pack never instantiates a
  provider — `chat_llm_responder` is an `@[LLMBehavior]` declared with
  `max_tokens`/`temperature`, and the deterministic `ChatModel` in
  `chat_spec.cr` drives the pipeline. `make_llm_responder`/`_chat_llm_respond`
  fold into that annotation. LLM/lifecycle events are read from the runtime
  store (`store.iter_events`), not `graph.events` (projection-only), and
  candidate `status` flips to `"sent"` immediately via communication's
  `response_dispatcher`. Duplicate `profile_context_view` is avoided by
  registering the principal before the profile (upstream's two-phase
  `run_until_idle`). Fixture scripts are driven by
  `spec/chronicle_packs/chat_spec.cr`.
- `email` declares the full manifest surface (3 object types, 4 relation
  types, 3 behaviors, 2 tools, `EmailSettings`). `email_ingester` turns an
  inbound `email_message` into `Source` (kind=email) + `CommMessage`
  (channel=email, direction=inbound) + `EmailThread`, deduping by
  `message_id` and continuing threads via `In-Reply-To`/`References`
  (registry + `email_thread_contains`, auto-created threads when
  `auto_create_threads`). `reply_drafter` formats `CommResponseCandidate`
  (channel=email) → `EmailDraft` with `Re: ` + stripped subject, original
  sender, and optional signature. `send_approver` gates sends: external
  recipients (or empty `to_addrs`) while `require_approval_for_external?`
  creates an `Action(kind=approval_request, risk_class=high,
  proposed_by=send_approver)`; owner/trusted-domain recipients auto-send by
  patching draft + candidate `status` to `"sent"` inline (`patch_object`
  never re-triggers `object.created`, so the "approved" → response_dispatcher
  chain is not used). `_is_internal` treats an address as internal when it is
  an owner address or its domain suffix matches `trusted_domains`. Body
  payloads are truncated to `max_body_length`. Fixture scripts are driven by
  `spec/chronicle_packs/email_spec.cr`.
- `schedule` declares the full manifest surface (3 object types, 2 relation
  types, 2 behaviors, 4 tools, `ScheduleSettings`, plus the
  `schedule.create_reminder` capability declaration — risk_class=low,
  action_class=R3 per upstream ADR 0016). The reminder capability is
  implemented in `Schedule::Capabilities.register_reminder_capability`
  (upstream `schedule/capabilities.py`): the handler reads the graph bound
  by the host via `Schedule::Capabilities.bound_graph` (the established
  capability seam — the ported gateway passes input_data only, no
  `execution_context` graph injection), creates a `once`/`interval`
  schedule whose payload is a pre-approved `comm_response_candidate`
  (`metadata.reminder=true`), and the gateway records the capability_call.
  The clock lives at the edge:
  `create_schedule_fn` / `emit_due_ticks_fn` take a synthetic `now` (ISO
  8601), so every fixture is deterministic; the pack never reads the wall
  clock. `emit_due_ticks_fn` is idempotent by `'{schedule_id}@{due_at}'`
  dedup_key and emits `schedule_tick` → `tick_of` relation. `tick_router`
  emits the schedule's payload with `metadata.schedule_id/tick_id/fired_at`
  injected (heartbeats get `sequence` stamped) and records an
  `emit_skipped` note on the tick when the payload type is unregistered;
  it is declared with `priority: 1` so it runs before
  `schedule_bookkeeper` — the Crystal runtime sorts same-event behaviors by
  `(-priority, name)`, and upstream's declaration order (`tick_router`
  first) must win so a `once` schedule emits before it auto-disables.
  `schedule_bookkeeper` advances `next_due_at` from the tick's `fired_at`
  (catch_up='skip': missed periods fire once, not replayed) and auto-disables
  `once` schedules. `_iso` emits a `+00:00` offset to match Python's
  `isoformat`. Fixture scripts are driven by
  `spec/chronicle_packs/schedule_spec.cr`.
- `research` declares the full manifest surface (9 object types, 9 relation
  types, 5 behaviors, 3 tools, `ResearchSettings`). `paper_ingester` turns a
  `source` (kind=research_paper) into `Paper` + `Author`(s) + `Venue`,
  deduping by source id via `paper_registry`, reusing venues by normalized
  name (`venue_registry`), classifying the venue kind as
  `conference`/`journal` from the name, and wiring `derived_from_source` /
  `published_in` / `authored_by`. `claim_extractor` and `idea_atom_extractor`
  are deterministic mock stubs (no LLM) — the former splits abstract
  sentences into `observation`(category=fact, confidence=0.75, metadata
  marks `extracted_by`) with `grounds` relations, the latter builds
  `IdeaAtom`s from keyword templates with ramp-up `novelty_score`/
  `coherence_score` and `proposes_idea` relations. `hypothesis_generator`
  creates a `research_direction` per qualifying (coherence ≥
  `min_coherence_for_hypothesis`) atom, deduping/merging by sorted-tag key;
  `research_direction_synthesizer` creates a higher-confidence synthesized
  direction when the atom count crosses `min_ideas_for_direction`
  (`synth:{tag}` key). Both are gated on `auto_synthesize_directions` and
  both merge via explicit `_merge_patch` (chronicle's `patch_object`
  replaces, upstream merges). Direction titles capitalize tags like Python's
  `str.title()`; the shared `_DIRECTION_REGISTRY` and `_IDEA_ATOMS_BY_PAPER`
  are cleared by `clear_research_registry` between fixtures. Tools use the
  host-bound graph seam and `_tool` suffix as identity_auth; `abstract` is a
  Crystal keyword, so the ported parameter is `abstract_text`. The upstream
  `paper_ingestion_pipeline` and `direction_synthesis` fixtures are driven
  by `spec/chronicle_packs/research_spec.cr`.
- `codebase` declares the full manifest surface (9 object types, 8 relation
  types, 5 behaviors, 4 tools, `CodebaseSettings`). `repo_ingester` turns
  `source` (kind=github_webhook | repo_file | repo_manifest) into a `Repo`,
  deduping by `full_name` (`repo_registry`) and wiring
  `derived_from_source`. `issue_tracker` handles kind=issue or
  github_webhook event=issues/issue sources, deduping by
  `"full_name#number"` (`issue_registry`), auto-creating a Core `task`
  (priority=high when a `bug` label, otherwise medium) only for open issues
  when `auto_create_issues_as_tasks`, and wiring `issue_in_repo` +
  `derived_from_source` (+ `action_creates_task`, undeclared so the
  validator passes it through, matching upstream). `adr_extractor` parses
  ADR-markdown `repo_file` sources whose path matches
  `adr_path_patterns`, extracting the `# title`, an `adr_number` from the
  filename, status from content keywords (deprecated/proposed/superseded,
  else accepted), and the `## Context`/`## Decision`/`## Consequences`
  sections; Crystal's `m` regex flag is MULTILINE+DOTALL, so the title
  capture uses `[^\n]+` (Python's `re.MULTILINE`). `change_summarizer`
  folds github_push/code_change or push/pull_request webhook sources into a
  `CodeChange` (deduped files, commit_sha from `after`/first commit id,
  author from pusher/sender, `N commit(s): ...` summary). `dependency_auditor`
  reads the repo's source metadata `dependencies`, flags
  `has_known_vulnerability` only when severity ≥
  `vulnerability_severity_threshold`, and wires `repo_depends_on`. Closed
  Literal sets (`DependencyKind`, `IssueState`, `PullRequestState`,
  `AdrStatus`) are enums. Tools use the host-bound graph seam and `_tool`
  suffix as identity_auth. The upstream `repo_and_issue_tracking` and
  `code_change_tracking` fixtures are driven by
  `spec/chronicle_packs/codebase_spec.cr`.
- `team_ops` declares the full manifest surface (6 object types, 7 relation
  types, 4 behaviors, 5 tools, `TeamOpsSettings`). `task_triager` promotes
  observations whose `category` equals `task_candidate_hint`, whose metadata
  has `task_candidate: true`, or whose category is `action_item` into Core
  `task`s (title=text[:80], status=candidate), wiring `part_of_project` /
  `part_of_milestone` when the metadata carries ids and creating an
  `assignment` (via `_extract_owner_from_text` or metadata `owner_ref`) only
  when `auto_assign_tasks`. `assignment_suggester` creates `assignment`s for
  owner-ref'd tasks, skipping tasks `task_triager` already assigned
  (`task_assignments` registry) and auto-creating a `review_request` for
  critical-priority tasks when `require_review_for_critical_tasks` (the
  registry short-circuit is why task_triager-promoted critical tasks don't
  double-assign). `milestone_tracker` keeps the open-milestone registries
  (used by triage linking). `completion_verifier` turns decision/fact
  observations mentioning completed/done/finished/closed/resolved with a
  metadata `task_id` into `completion_evidence` and patches the task's
  status to `done`. `create_project_fn`/`create_milestone_fn`/`assign_task_fn`/
  `mark_task_done_fn` are the ported tool behaviors (milestone wires
  `part_of_project`, evidence wires `evidence_for` and patches task done).
  Closed Literal sets (`ProjectStatus`, `MilestoneStatus`, `ReviewType`,
  `ReviewStatus`) are enums. Tools use the host-bound graph seam and `_tool`
  suffix as identity_auth. The upstream `task_triage_and_assignment` and
  `completion_workflow` fixtures are driven by
  `spec/chronicle_packs/team_ops_spec.cr`.
- `meeting` declares the full manifest surface (5 object types, 7 relation
  types, 4 behaviors, 4 tools, `MeetingSettings`). `transcript_ingester`
  turns a `source` (kind=meeting_transcript) into a `Meeting` +
  `TranscriptSegment`s, parsing the content in priority order (JSON
  array/object → structured `Speaker: text` lines → sentence-split plain
  text), flagging segments via the settings keyword lists, and wiring
  `derived_from_source` + `segment_of`; it is idempotent per source id via
  the `meeting_registry`. `decision_extractor`/`action_item_extractor`
  fire on flagged `transcript_segment` objects — the decision extractor
  creates `meeting_decision` (confidence 0.80, `decided_by`=speaker,
  `decision_in` + `decision_from_segment`), the action-item extractor
  creates a Core `task` (title `[Meeting] ...`, status=candidate,
  priority=medium) and `meeting_action_item` (`action_item_in`,
  `action_item_from_segment`, `action_creates_task`) but returns before
  creating anything when `auto_create_tasks_from_action_items` is false
  (the upstream gate precedes both objects). `meeting_summarizer` writes a
  `meeting_note` (note_type=summary) on `meeting.created` when
  `auto_summarize_meeting`. Closed Literal sets (`MeetingPlatform`,
  `MeetingStatus`, `ActionItemStatus`, `NoteType`) are enums. Tools use the
  host-bound graph seam and `_tool` suffix as identity_auth;
  `add_action_item_fn` mirrors upstream by creating the Core task with
  `owner_ref`/`due_at` and linking `action_creates_task`. The upstream
  `transcript_ingestion_pipeline` and `manual_meeting_workflow` fixtures are
  driven by `spec/chronicle_packs/meeting_spec.cr`. `_mock_summary` is
  ported for surface parity (unused by the v0.1 behaviors, matching
  upstream).
- `subject_profile` declares the full manifest surface (3 object types, 5
  relation types, 1 behavior, 2 tools, `SubjectProfileSettings`).
  `apply_subject_fact_verdict` fires on a `subject_fact_verdict` created
  with `status=proposed` (the where clause uses the flat chronicle payload
  keys `{"type" => "subject_fact_verdict", "data.status" => "proposed"}` for
  upstream's `object.type`/`object.data.status`), and fails closed through
  explicit verdict `status` patches: a non-`profile_candidate` candidate, an
  evidence whose `normalized_metadata.subject_scope` is not
  `owner_profile` (the security boundary), or an empty resulting value all
  mark the verdict `failed` (with `metadata.error`
  `owner_subject_scope_required`/`empty_value`). A `reject` verdict
  invalidates the candidate; `confirm`/`correct` promote a `subject_fact`
  (deterministic `_stable_id` SHA-256 identity, `trust=confirmed_trust`,
  exact evidence provenance) with `promoted_from_profile_candidate` +
  `subject_fact_grounded_in`, patch the verdict `applied` (with
  `result_fact_id`), and — for a corrected value that conflicts with a
  prior promoted fact — mark the prior `contradicted` and open a
  `subject_contradiction` (`contradiction_involves` ×2). All verdict/candidate/
  fact `status` patches use an explicit top-level merge (chronicle's
  `patch_object` replaces data, upstream merges). The upstream `view` is
  served by `graph.objects` (chronicle behaviors have no view). The tools
  use the host-bound graph seam and `_tool` suffix as identity_auth;
  `forget_subject_fact_fn` raises `PackError` on a non-`subject_fact` target
  (upstream `ValueError`), supersedes the original via an auditable
  `subject_fact_forget_*` tombstone, and wires `subject_fact_supersedes`.
  The pack has no upstream fixture script; behavior coverage lives in
  `spec/chronicle_packs/subject_profile_spec.cr`, which drives the
  activity_normalizer `profile_candidate`/`activity_evidence` inputs
  directly (the graph validator passes unregistered types through).
- `telegram` declares the full manifest surface (1 object type, 1 relation
  type, 2 behaviors, 1 tool, `TelegramSettings`, plus the
  `telegram.send_message` capability declaration — risk_class=low,
  credential_ref=TELEGRAM_BOT_TOKEN, action_class=R3). It is a pure
  transport adapter: `telegram_ingester` turns a `telegram_update` into a
  `chat_input` (`user_ref='telegram:<user_id>'`, metadata.channel=telegram,
  adapter routing data) and wires `ingested_as`, leaving everything
  conversational to the Chat Pack; `telegram_dispatcher` turns an approved
  `comm_response_candidate` (channel=telegram) into a `capability_call`
  (telegram.send_message, risk from `outbound_risk_class`, `delivers`
  relation, candidate metadata stamped with `delivery_call_id`), so outbound
  sends are ordinary policy-checked gateway capability calls — the adapter
  never touches the network or the credential. Porting the dispatcher
  required fixing the communication `delivers` relation declaration to match
  upstream (open source → `comm_response_candidate`, previously wrongly
  constrained to `comm_response_candidate → comm_message`). `submit_telegram_update`
  normalizes the Bot API wire shape (chat/user ids coerced via str(), raw
  trimmed for audit; non-message updates return nil). The in-process
  `_SEEN_UPDATE_IDS` at-least-once dedup guards twitchy pollers
  (`clear_seen_updates` between fixtures). The capabilities module
  (`SendMessageInput`, `_send_message`, `register_send_capability`) and the
  long-polling driver (`poller.py`: `_get_updates`/`_post_to_server`/
  `run_poller`) are ported with injectable `http_get`/`http_post` seams (and
  a `token_provider` seam for the send handler, since the ported gateway
  handler signature receives only input_data, not execution_context) so the
  network edge is testable offline and fails closed without a token. The
  four upstream fixtures — owner conversation, stranger deflection, update
  dedup, and held outbound (risk=high → approval with live principal
  verification → delivery) — are driven end-to-end through core +
  tool_gateway + identity_auth + communication + chat by
  `spec/chronicle_packs/telegram_spec.cr`.
- `whatsapp` declares the full manifest surface (1 object type, 1 relation
  type, 2 behaviors, 1 tool, `WhatsAppSettings`, plus the
  `whatsapp.send_message` capability declaration — risk_class=low,
  credential_ref=WHATSAPP_ACCESS_TOKEN, action_class=R3). It is the
  structural mirror of the telegram adapter, differing only in wire shapes
  and identity refs: `whatsapp_ingester` turns a `whatsapp_message` into a
  `chat_input` (`user_ref='whatsapp:<phone>'`, metadata.channel=whatsapp,
  `to_number`/`wamid` adapter routing) and wires `wa_ingested_as`;
  `whatsapp_dispatcher` turns an approved `comm_response_candidate`
  (channel=whatsapp) into a `capability_call` (whatsapp.send_message,
  input `{"to", "text"}`, `delivers` relation, candidate metadata stamped
  with `delivery_call_id`). `submit_whatsapp_webhook` unwraps Meta's Cloud
  API envelope (`entry[].changes[].value.messages[]`) with a contacts
  profile-name lookup and skips non-text messages entirely. The in-process
  `_SEEN_MESSAGE_IDS` wamid dedup guards Meta's at-least-once webhook
  delivery (`clear_seen_messages` between fixtures). The capabilities module
  (`SendMessageInput`, `_send_message`, `register_send_capability`) posts to
  `{api_base}/{phone_number_id}/messages` with a Bearer token and fails
  closed without a token or a configured `phone_number_id`; the token is
  pulled from an injectable `token_provider` seam (the ported gateway
  handler signature receives only input_data, not execution_context). The
  four upstream fixtures — owner conversation, stranger deflection, webhook
  dedup, and non-text-message skipping — are driven end-to-end through core
  + tool_gateway + identity_auth + communication + chat by
  `spec/chronicle_packs/whatsapp_spec.cr`.
- `composio` declares the full manifest surface (zero object/relation/
  behavior types, 2 proposal tools, `ComposioSettings`, plus the
  `composio.connections.link` (risk_class=high, action_class=R4) and
  `composio.connections.status` (risk_class=low, action_class=R0)
  capability declarations). It is an optional thin route, never a canonical
  service identity: `request_composio_link_fn`/`request_composio_status_fn`
  propose `capability_call`s through the Tool Gateway (governed, held for
  R4/link), and the registered capabilities drive an injectable
  `ComposioTransport` seam (`configure_composio_transport`/`composio_transport`).
  The client layer is ported: `resolve_catalog_tool` hardens canonical
  candidates into one concrete provider tool version (dedup'd candidates,
  toolkit-scoped catalog rows, version selection with `latest` → current,
  deprecation rejection, `shape_fingerprint` receipt), `store_redirect`/
  `take_redirect` keep bearer-like Connect Links out of graph output and
  event history (https-origin validation + `safe_sha256_fingerprint`, with
  the fixture asserting the origin survives while the full `/link/...` path
  never reaches `capability_result.output_data`), and `connection_summary`
  returns only non-secret identity/status fields. `SDKComposioTransport` is
  ported but fails closed with `ComposioUnavailable` — there is no Crystal
  Composio SDK (upstream raises the same on an SDK import miss); hosts wire
  a real transport via the seam. The upstream Connect Link fixture (core +
  tool_gateway + composio, fixture transport, register capabilities, propose
  → hold → approve → execute → stored redirect) is driven by
  `spec/chronicle_packs/composio_spec.cr`.
- `gmail` declares the full manifest surface (2 object types, 2 relation
  types, 9 behaviors, 7 tools, `GmailSettings`, plus the 7 canonical
  `gmail.*` capability declarations — drafts.create=R2, drafts.send=R3, the
  five R0 reads). It is the first full connector-conformance case:
  `request_gmail_exploration_fn` proposes two budgeted R0 probes
  (`profile.get`/`labels.list`) through the gateway and
  `gmail_exploration_projector` turns the recorded replay artifacts into an
  active `integration_profile` (with `aggregator_profile` for the composio
  route, capability inventory, claims, data topology, and the history
  watermark), a `source_connection_request` (→ usage `connection_surface`),
  and a `backfill_cursor`. `request_gmail_backfill_fn`/
  `propose_gmail_page_fn` drive bounded multi-page sync; the
  `gmail_sync_result_ingester` imports provider-neutral `acquired_item`/
  `acquired_content` handoffs (replay artifacts, never mailbox bodies in the
  graph), advances the cursor, and records provider failures via
  activity_normalizer (`rate_limited`/`auth_expired`/`cursor_invalid`/
  `unexpected_shape` classification, profile drift marking, and
  `reanchor_required` for cursor invalidation). `request_gmail_poll_fn`
  reads history from a provider watermark, spawns `messages.get` hydration
  calls, records deletion tombstones (`evidence_invalidation_request` →
  activity_normalizer revokes matching evidence and usage marks it
  invalidated), and settles a missing history message as a concurrent
  deletion. The draft lifecycle is local-first: `create_gmail_draft_candidate_fn`
  is an R1 `gmail_draft_candidate` (no provider write); `request_gmail_draft_sync_fn`
  proposes an R2 `drafts.create` that must be explicitly approved before
  `gmail_draft_result_projector` flips the draft to `synced` with a provider
  draft id; `request_gmail_draft_send_fn` proposes an R3 `drafts.send` that
  is never auto-run (re-proposing is idempotent on the held call). The
  conversation family mapping (`materialize_gmail_run_fn`) runs locally over
  recorded evidence (`reprocess_gmail_evidence_fn` never contacts the
  provider), reusing the communication family materializer and the
  connector_control adapter (`adapt_gmail_run_fn` + maintenance handler)
  so the neutral control plane stays authoritative. Route adapters are
  injectable (`register_gmail_capabilities` accepts `execute_route`/
  `resolve_route`/`route`, so a native route works with no Composio
  dependency). The closed string sets (`SyncMode`, `SyncStatus`, `ErrorCode`,
  `DraftStatus`) are enums. The upstream test surface
  (`tests/test_gmail_connector.py` — explore/backfill/poll/revoke,
  history-404 settlement, interrupted-restart, bound-hit partial, local
  draft R1/send-holds, unexpected-shape drift, rate-limit retry + invalid
  cursor reanchor, non-composio route) and the fixture cascade are driven by
  `spec/chronicle_packs/gmail_spec.cr`; the fixture `main` CLI is skipped
  (`fixtures/run_fixtures.py::main`) and the Pydantic `_StrictModel`
  `extra=forbid` is not enforced.
- `mcp` declares the full manifest surface (3 object types — `mcp_server`,
  `mcp_exposure`, `mcp_access` — zero relations/behaviors/tools,
  `MCPSettings`, plus the `mcp.set_exposure` capability declaration —
  risk_class=high, action_class=R4). It is bidirectional. **Outbound**
  (`client.cr` + `registry.cr`): `StdioTransport`/`HttpTransport` speak
  JSON-RPC 2.0 (stdio framing over a subprocess; streamable HTTP with JSON
  or SSE responses and `Mcp-Session-Id` echo — the HTTP POST is an
  injectable seam so the deterministic specs never touch the network);
  `MCPClient` is the protocol layer (handshake, `list_tools`, `call_tool`,
  `call_tool_text`). `connect_and_register` discovers a server's tools and
  registers each as a gateway capability (`mcp_<server>.<tool>`): high risk
  by default (approval-required), action-classed R3 by default (ADR 0016,
  never derived from the risk label), per-tool `tool_risk_overrides` /
  `tool_action_class_overrides` as explicit operator statements, JSON-schema
  input schemas from the tool's `inputSchema`, and an `mcp_server` audit
  object (connected/unreachable; `register_configured_servers` isolates one
  broken server). **Inbound** (`server.cr`): `MCPGateway.handle_jsonrpc`
  takes a parsed JSON-RPC message + bearer token; `resolve_caller` maps a
  configured token to a caller identifier whose role comes from Identity/Auth
  (`identity_unverified` single-user mode when no principals are registered,
  fail-closed on unknown identifiers); `exposure_allows` is fail-closed over
  graph-native `mcp_exposure` rules (latest rule per surface wins; per-tool
  `tool:<key>` overrides the generic `tools` gate); `set_exposure_fn` is the
  agent-editable-config seam behind the governed `mcp.set_exposure`
  capability (held for owner approval, then applied); `_call_capability`
  routes exposed capabilities through the SAME gateway path as the
  assistant's own tool use (record → policy → execute-or-hold), and every
  inbound call — allowed or refused — is an `mcp_access` audit object. The
  upstream test surface (`tests/test_mcp_client.py` — handshake/discovery,
  schema mapping, governed registration, held-vs-executed, injection
  posture, R3-default + ceiling ineligibility, per-tool action overrides —
  and `tests/test_mcp_inbound.py` — caller matrix, exposure defaults and
  per-tool overrides, chat/memory dispatch, governed capability call +
  approval, audit trail, set_exposure held-then-applied) plus the four
  fixture scenarios are driven by `spec/chronicle_packs/mcp_spec.cr`; the
  fixture `run_all` CLI is skipped. Divergences: the MCP `MCPClient.initialize`
  handshake method is `handshake` (Crystal reserves `initialize` for the
  constructor); `register_set_exposure_capability` uses the pack's
  `bound_graph` seam and `updated_by: "gateway"` because the ported gateway
  handler receives only `input_data`, not an `execution_context` with a
  graph/call id; `schema_model_from_json_schema` returns a plain JSON Schema
  object instead of a dynamic Pydantic model (the MCP server revalidates on
   its side); and the `mcp_exposure` enabled/`mcp_access` allowed booleans
   use `getter?` predicates.
- `bridges/diligence_core` declares the full manifest surface (zero
  object/relation types, 4 behaviors, `DiligenceCoreBridgeSettings`, empty
  in v0.1). `document_to_source`/`claim_to_observation`/`memo_to_artifact`/
  `risk_to_evaluation` subscribe to `object.created` by type name
  (document/claim/memo/risk), read the flat chronicle payload
  (`payload["id"]`/`payload["data"]` for upstream's nested `object` read),
  and emit Core equivalents — `source` (kind=document), `observation`
  (category=fact), `artifact` (kind=memo, assembled markdown body,
  status=draft), `evaluation` (judgment=severity,
  evaluator=diligence_core_bridge) — each carrying a `derived_from` relation
  to its Diligence origin (bridged observations additionally wire `grounds`
  to any bridged source document). Python's falsy-on-empty `or` fallbacks
  are ported via a `_or` helper (empty string → default); the upstream bare
  `except: pass` guards around every `add_object`/`add_relation` are ported
  as bare `rescue`s. The `_BRIDGE_SEEN` registry (`DiligenceCore.bridge_seen`)
  dedupes per diligence object id, so replayed `object.created` events
  bridge once (guarded by `has_key?`, not `in?` — Hash `in?` compares
  key-value tuples). The upstream fixture's stub Diligence pack schemas are
  replaced by direct object injection (`spec/chronicle_packs/
  diligence_core_spec.cr` drives both fixture scenarios and the replay-dedup
  case; the graph validator passes unregistered types through). Core's own
  `observation_extractor` also fires on bridged `source` objects, matching
  the upstream fixture (Core loads alongside the bridge).
- `evolution` (slices 1–3): the deterministic graph-native surface is
  ported; the Crystal candidate static-gate path is partial; Python-bound
  machinery is deferred. **Partial**: the Crystal candidate pipeline parses
  `pack.cr` with the Crystal compiler parser, checks its own manifest/file/
  surface/require/construct/reserved/size/injection boundaries, and records
  the fail-fast audit trail through `proposal_gatekeeper`. It is not a port of
  Python `ast` or import semantics. **Intentional language boundary**:
  Python-candidate static-gate parity (`analysis.py`/`gates.py`), dynamic
  pack import (`materialize.import_pack` is `importlib`), the Python LLM
  author, and Python fixture modules are not ported because candidates are
  Crystal only. **Pending Crystal-native work**: isolated compiled-candidate
  trials/soak (`trial.py`/`soak.py` define the required child-process,
  wall-clock, resource-limit, and persisted-fork outcomes), activation
  (`adopt.process_adoption_tickets` needs Crystal loading + fork promotion),
  boot reload/retention (`boot.py`), and a keyless Crystal author with
  deterministic Crystal scenarios. `review.py` is ported; its unified diff
  uses the `similar` shard. **Ported**: 8 object types + 5 relation
  types (`struct` + `@[ObjectType]`/`@[RelationType]`, `getter? enabled`
  for the master switch); `EvolutionSettings` with the upstream defaults
  (consts nested so the DSL pack macro treats them as data); `author_frame`
  (charter text embedded byte-identical to the pinned vendor file and
  `sha256:`-pinned by `charter_text_and_hash`; the closed
  `ADMISSIBLE_FIELD_PATHS` set; `validate_structured_fields` charset
  checks with Python-`!r`-style single-quoted messages; Crystal-native
  `Analysis` (compiler-parser syntax refusal, manifest + `pack.cr` file
  contract, allow-listed dependencies plus authored-only relative `require`
  paths, process-spawn and compile-time-shell refusal, and extraction of the
  manifest-derived, type-validated two-way behavior/tool/type/capability
  surface (including two-way capability risk/action classes); protected provider
  namespaces, pack names, and never-LLM-callable names refused
  without executing candidate code; a typed, fail-fast Crystal static-validation pipeline
  validates the manifest's runtime-grammar name and PEP 440 version against
  the proposal,
  then rejects nonempty reserved manifest signatures until a verification
  algorithm exists, validates canonical `sha256:` content- and external
  bundle-pin formats, and revalidates both its source-only content pin and
  artifact-reconstructed bundle pin before semantic source checks; it drives `proposal_gatekeeper` to
  a per-gate, audit-linked `rejected` first failure, source-injection
  `suspended` result, or `gated` static-completion transition in upstream gate
  order);
  `recompute_drafting_taint` ignores the record's stored flags and unions
  flags read fresh from admitted object ids, plus an owner-content
  injection tripwire); `materialize.proposal_files`/`write_files`/
  `bundle_hash_of` (the pin rides chronicle's `compute_bundle_hash`), and
  `materialize_verified` (proposal artifacts → fresh Crystal candidate tree
  → external bundle-pin verification, without candidate loading), and
  `adopt`'s durable disable-ticket processor (including vanished-promotion
  abort, idempotent rollback records, and same-pack active-promotion
  supersession);
  the tools — `submit_proposal_fn` (bundle pin at submission,
  drafting-record taint recompute + structured-field refusal),
  `open_reflection_gap_fn` (deterministic taint union over the review's
  full input set), `request_adoption_fn` (governed critical hold via
  tool_gateway); the behaviors — `gap_detector` (threshold + one-open-gap-
  per-capability + taint union, no-ops when disabled), `promotion_recorder`
  (promote.applied marker → active + proposal promoted),
  `watch_monitor` (scans the event log sorted by sequence for in-window
  attributable behavior.failed, one reflection gap per adopted pack);
  `render_trial_driver` (deterministic driver bytes with Python-style
  single-quoted repr of replay types); and `register_adoption_capabilities`
  (the two refusals — auto-approvable critical and no verified approver —
  and the ticket-writing executors behind a host `bound_graph` seam).
  Object reads use `graph.objects` and the log scan uses `graph.events`
  sorted by sequence (chronicle's `ctx.view` is empty unless context-read
  tracing is enabled). Slice 2 ports the review decision surface
  (`review.py`): `build_review` is a pure read over the objects the
  pipeline already wrote, `_manifest_view` parses the proposal's
  manifest.toml with the `toml` shard (never trusted, only displayed),
  and the per-file unified diff rides the `similar` shard
  (dsisnero/similar.cr, now a declared dependency) configured with
  `diff_slices(old.lines, new.lines)` + context radius 3, which matches
  Python difflib's `unified_diff(..., lineterm="")` line output exactly.
  `render_review_html`/`render_approvals_index_html` reproduce the
  upstream page byte-for-byte in structure (CSS/JS constants verbatim),
  and agent-authored text is HTML-escaped everywhere it appears. All
  status patches in the behaviors (proposal_gatekeeper's taint-suspend,
  promotion_recorder's active flip, request_adoption's pending_approval)
  use an explicit `_merge_patch` because chronicle's `patch_object`
  replaces the whole data hash while upstream merges — without it a
  patch wipes sibling fields like `gap_id`.
- `activity_normalizer`: all 13 object types and
  8 relation types are `JSON::Serializable` structs. The
  `normalize_acquired_item` behavior owns provider-neutral evidence identity
  (`evidence_{sha256(source_surface_id, dedup_key)}`), bumps `revision_number`
  per distinct `content_hash` (idempotent on hash match), supersedes the
  prior revision by patching only its `status` (chronicle's patch replaces,
  so the merge is explicit), and wires `content_for`/`normalizes_to`/
  `acquired_from`/`supersedes`. The legacy evidence→candidate path
  (`run_extraction`, default off per ADR 0026) runs the zero-key
  `StructureExtractor` idempotently by `extraction_identity` and records
  typed candidates + `produced_candidate`/`extracted_from`. The replay
  store (`replay.py`) is ported: content-addressed SHA-256 artifacts, portable
  chunked locators for passage through secret sanitizers, and
  `read_replay_payload` (inline verification / artifact-store reads /
  reference_only rejection), which `normalize_acquired_item` calls for
  non-`reference_only` acquisitions. Cursor behaviors publish
  `source.cursor_advanced` on `backfill_cursor` creation and `patch.applied`;
  `fulfill_evidence_invalidation_request` revokes matching current evidence
  (idempotent fulfilled no-op outside the retained window) and emits
  `source.evidence_invalidated`. The graph tools `reextract_evidence` (from
  the retained payload, emitting `replay.verified`) and
  `disable_extractor_version` (invalidates records + candidate provenance,
  preserving evidence) are `@[Tool]` wrappers over the host-bound seam.
  The ADR 0026 shared-extraction tail is now complete: the structure
  annotation extractor (`activity.structure@0.2.0`) registers at the shared
  semantic_extraction seam and emits the legacy drafts as namespaced
  `activity.*` facets; `project_structure_candidates` mints the same legacy
  candidates (deduped by the legacy identity); `select_shared_extraction`
  routes the `activity.*` facets onto the shared layer the moment the
  seeded profile appears; and `migrate_communication_extraction_floor`
  upgrades stack-owned profiles with the bounded communication floor.
- `semantic_extraction` (slice 1 of 2, in progress): 11 typed object types +
  8 relation types; the `semantic_annotation` envelope carries
  annotation_identity/facet/body/selector/extractor identity/config hash/
  attribution/modality/polarity. The deterministic zero-key floor
  (`DeterministicExtractorV1`, `semantic.deterministic@0.1.0`) implements
  entity_mention (email/url/handle/proper-noun with overlap dedup),
  assertion (sentence-level, modality/polarity cues), question,
  preference_expression, temporal_expression (ISO/MDY/DMY/MY date
  normalization), and topic_tag (frequency-ranked) — byte-deterministic and
  capped per facet, registered through the shared extractor registry.
  `run_annotation_extraction` is cache-identified by
  `(revision, extractor identity, config_hash, requested_facets)` with
  per-facet coverage; `seed_extraction_profile` mints the D041 eager-floor
  profile, and `annotate_evidence` runs it eagerly per evidence revision,
  emitting `extraction_run` + `semantic_annotation` (annotation_for/
  produced_annotation/run_for) + `extraction_coverage`. Selection extraction
  (`extract_selected_evidence`) settles exact-span requests with
  evidence/revision verification and the pack-owned hash verification +
  offset remapping inside `run_profile_extraction`. The guarded
  proceduralization lifecycle (ADR 0029) declares a deterministic
  request-rule procedure from reviewed reference annotations, evaluates it
  graph-direct (no runtime fork; parity over the (facet, start, end, exact)
  selector keys), and promotes it approver-gated; the ADR 0014
  fork-trial-promote surface compares a candidate against the baseline
  drafts-only. The `LLMExtractorV1` (semantic.llm@0.1.0) rides a
  `RecordedCompletion` boundary (durable llm.requested/responded +
  idempotency-key replay) and verifies every LLM-proposed span
  byte-for-byte before materialization. The `Facet` enum models the closed
  standard set; facet FIELDS stay String because activity_normalizer
  registers dotted extension facets (`activity.preference`, `task`) against
  the same contract. Remaining deferred: the fixture generators
  (`fixtures/run_fixtures.py`, `fixtures/seed_llm_records.py`).
- `connector_control` materializes 6 `JSON::Serializable` struct types with
  zero relation types. The record adapters are idempotent upserts keyed by a
  sha256 `*_identity` (immutable provenance fields cannot change; changed
  fields merge onto the existing object via chronicle's replace-patch).
  `record_connector_binding` accumulates routes across refreshes;
  `record_connector_run_observation` derives health per state and appends
  attempt/update/terminal/success event ids; `record_connector_learning_delta`
  caps refs/exceptions by settings; `record_connector_native_view` validates
  the family payload through the `contracts.cr` family models. The control
  plane and learning-delta projections are pure sorted reads. Maintenance is
  a handler registry: `request_connector_refresh` validates the binding
  (single, active, manual-refresh-capable), rejects already-running surfaces,
  and dispatches a registered service handler (accepted with `domain_run_id`
  or failed with a bounded error). Behaviors seed the versioned operational
  policy once (`seed_connector_operational_policy`, idempotent by
  `policy_identity`) and project `source.lifecycle_changed` onto binding
  status. `measure_connector_run`/`operational_budget_violations` implement
  the non-persisted conformance measurer against the seeded policy.
- `usage` materializes 7 typed object types and 3 relation types. The tool
  adapters are idempotent: `connect_surface_fn` mints exactly one surface
  (reconnect emits a new `source.connected` fact without a second surface,
  and immutable fields cannot change), `record_source_clock_fn` is
  clock_id-idempotent for live surfaces only, and `record_usage_fn` rejects
  a divergent fact for the same `usage_identity`. Behaviors are
  event-driven: `fulfill_source_connection_request` (connectors request,
  Usage owns identity), `observe_normalized_evidence` (indexes
  `usage_evidence` + evaluates the gate, settling/settling/settled),
  `observe_cursor_progress`/`observe_source_clock`/`observe_surface_connection`
  re-evaluate without duplicating settlement, and
  `observe_evidence_invalidation` de-qualifies without erasing. Gate
  semantics are immutable (`usage.category.default@1` rejects mutation).
  `project_usage_fn` replays the log through an explicit event horizon into
  surfaces/coverage/usage/outcome projections; the settlement and coverage
  sub-objects are typed `record` structs (`SettlementProjection`,
  `CoverageStats`). Tool parameters are typed `record` structs with an
  ISO-8601 `Time` converter; bools avoid `is_` prefixes (JSON key preserved
  via `@[JSON::Field(key: ...)]`).
- `tool_gateway` (complete): 10 typed object types + 8
  relation types. The capability registry (`CapabilitySpec` as a `record`,
  `register_local_capability`) dispatches registered handlers or a mock.
  `decide_policy_detail` evaluates the legacy risk dimension and the
  action-class dimension independently (never cross-inferred); the pure
  `evaluate_action_authority` fails closed on missing classes, gates R3/R4,
  and R2 auto-approval additionally requires a promoted standing scope
  (none ported yet, so R2 holds — the upstream fail-safe). The
  `sanitize_output` redactor and the deterministic injection scan
  (`scan_for_injection`/`wrap_untrusted` envelope) are ported; a host
  `credential_resolver` seam covers Secrets injection. The four core
  behaviors complete the lifecycle: `call_recorder` (calls relation),
  `policy_enforcer` (auto-approve → `capability_approval`, else hold at
  `policy_checking` carrying the per-dimension reasons),
  `call_executor` (fires only on approval, idempotent on the `approved`
  status), and `result_sourcer` (maps to a Core `source`). Approvals are
  resolved through `approve_capability_fn`/`deny_capability_fn` (approver
  verification against Identity/Auth when principals are registered;
  `identity_unverified` otherwise). Status transitions use the shared
  `Chronicle::Packs::CopyWith#define_copy_with` instead of hash merges.
  Slice 2 completes the surface: the capability catalog
  (`catalog_entries`/`register_catalog_capability`), registration
  enforcement (arm/disarm; undeclared pairs, risk/action drift, and
  disabled-pack claims refused), ADR 0018 standing scopes (propose/promote/
  demote/disable + the R2 auto-approval read path) and the
  `tool_policy_reliability_guard` behavior, the integration profile chassis
  (aggregator/profile/exploration receipts, stable ids and shape
  fingerprints), the reference `web.fetch_url` capability (host seam, fails
  closed), and the LLM tool proxies — `CrigGatewayTool` is a
  `Crig::DynamicTool` (Crig::ToolDyn) whose callback runs the shared
  gateway pipeline; Crig supplies only the tool transport (JSON args,
  ToolContext metadata persisted on the capability_call, ToolResult), the
  gateway owns the policy state machine.
- `memory_gateway` (slice 1 of 2, in progress): 6 typed object types + 5
  relation types. Closed string sets are Crystal enums — non-flags enums
  serialize as the underscored member name, so `ReliabilityVerdict::Harmful`
  → `"harmful"` and `ResolutionTier::AnnotatedEvidence` →
  `"annotated_evidence"` round-trip to the exact upstream value with
  `parse?` validation. The store is graph-backed (memory_item graph objects
  ARE the store; `lexical_score` = max of Jaccard overlap and query-term
  coverage). `candidate_evaluator` runs the acceptance policy (threshold +
  auto-accept category relief + provenance admission with Identity/Auth
  verification when principals exist); `memory_writer` promotes accepted
  candidates with subject-scoped dedup and LRU eviction; `memory_retriever`
  fulfills graph-visible retrieval requests; `memory_ranker` scores each
  result; `memory_reliability_applier` applies `reliability.changed` to an
  item.   `retrieve_memories_fn` returns outcome-adjusted ranked results, and
  `resolve_memory_query_fn` resolves over the evidence-authoritative tiers
  (raw evidence floor, annotations, admitted items) with source-trust
  arbitration from the attention pack, writing a `memory_query_resolution`.
  The EmbeddingService boundary (HashEmbedder/OpenAIEmbedder, per-graph
  recorded service with embedding.requested/responded + idempotency replay,
  space-aware cosine blend stored on memory_item with model/version
  identity, never blended across spaces) and versioned promotion
  (propose/resolve with approver-gated memory.promoted/memory.demoted,
  `memory_promotion_proposer`, `verify_memory_replay_fn`) are ported.
  Remaining deferred: the SQLite backend (the port's graph-backed store
  replaces it), the backend registry + external adapters (`Mem0Backend`).

## Inventory

- `plans/inventory/python_port_inventory.tsv` — 2080 API items (tree-sitter backend)
- `plans/inventory/python_source_parity.tsv` — 2080 source API items
- `plans/inventory/python_test_parity.tsv` — 638 tests (161/638)

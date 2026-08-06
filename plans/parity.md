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

**Progress: 741 / 2080 source API items ported, 51 skipped, 94 deferred.**

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
  wrappers. `verify_skill_replay_fn` is DEFERRED — chronicle lacks
  `Runtime#fork` (the fork-trial re-run); the portable replay pieces
  (  `SkillReplayIncompleteError`, `_recorded_usage`, `_lineage_gaps`) are
  ported, and the fork-based step lands with chronicle's fork support.
- `eval_outcome` models its nodes as `JSON::Serializable` structs:
  `OutcomeRecord`, `ArtifactReliability`, and the nested `ReliabilityTallies`.
  Outcome capture emits canonical `outcome.*` events that the
  `artifact_reliability_projector` folds into a typed, evidence-explainable
  reliability projection (emitting `reliability.changed`, which the skills
  pack's eligibility behavior consumes). Terminal outcomes are exclusive
  (correction requires supersession); maintenance outcomes are idempotent
  by contribution key. The upstream fixture also loads memory_gateway; the
  behavior/tool specs run without it.
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
- `plans/inventory/python_test_parity.tsv` — 638 tests

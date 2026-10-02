# Evolution Pack: design

**Status: IMPLEMENTED (src/chronicle_packs/evolution, Crystal candidate
path). This document is the Crystal counterpart of the upstream
`activegraph-packs` design of record. Upstream behavior is the source of
truth; the implementation-forced decisions were folded back into the same
commits that made them. The port accepts Crystal candidates only, so the
upstream Python-candidate mechanics (Python AST gates, `importlib` pack
import, Python fixture modules, a Python LLM author) are intentionally
divergent. See [plans/parity.md](../plans/parity.md) for the exact source and
test ledger boundaries.**

The evolution pack lets the assistant author new packs for itself, trial
them in isolation against its own history, and adopt them only after the
owner approves. Every step is graph state. The loop in one line:

```text
capability_gap -> mod_proposal -> static gates -> fork trial -> owner
approval -> load_pack + promote (quiescent) -> active -> monitor ->
disable/rollback
```

The differentiating claim this pack has to earn: self-modification with
provenance. OpenClaw-class assistants write skills with no gates and no
audit trail. Hermes-class assistants have a learning loop you cannot
inspect or replay. This pack runs the same loop on an event-sourced
substrate where the trial is a fork you can diff, the adoption is a
marker event you can trace, and the rollback is a state you can
reconstruct.

---

## 1. Runtime primitives this design consumes

The runtime primitives come from the pinned `chronicle` shard (the Crystal
port of the ActiveGraph runtime). The equivalent API names in this repo:

| Primitive | Role in the loop |
|---|---|
| `Chronicle::Runtime#fork(at_event, label:)` | Isolated trial environment with the parent's full history; requires a SQLite-backed runtime |
| `Chronicle::Runtime#load_pack(pack, settings, manifest_path:)` | Hot-load the candidate inside the fork; later, the governed load on the parent |
| `Chronicle::TraceFacade#events` / `#failures` | Trial evidence: what fired, what broke (`trace.failures` are `behavior.failed` events) |
| `Chronicle::Runtime#diff(other)` | The structural summary on the owner's decision surface (`Chronicle::Diff`) |
| `Chronicle::Runtime#promote(fork, dry_run:)` | Dry run returns `Chronicle::PromotePlan`; apply returns `Chronicle::PromoteResult` atomically and quiescently |
| `promote.applied` marker event | The single event behaviors may react to post-adoption; `PromoteResult#marker_event_id` |
| `Chronicle::Sandbox::LocalSubprocessTrialExecutor` (via `SandboxLifecycleService`) | Stage 3's process boundary: candidate execution in a fresh-interpreter child, pin-verified, three nets |
| `Chronicle::Retention.pins` / `.retire` (`RetentionPinnedError`) | §7.5: promoted-from fork logs refuse retirement; disposable trial forks archive at boot |

The upstream primitives `activegraph.sandbox.run_forked_trial`,
`activegraph.store.retention`, and the `activegraph.packs.manifest` helpers
map to `Chronicle::Sandbox`, `Chronicle::Retention`, and `Chronicle::Packs`
(`compute_bundle_hash` / `compute_content_hash` / `verify_bundle_hash`).

Consumption pattern for adoption, in order, inside one governed
executor. This is the single canonical order; §3 stage 5 restates it
with rationale. In this repo it is implemented by
`Evolution.process_adoption_tickets` (and `Chassis.sweep_evolution`):

1. Recompute gates against the proposal's pinned bundle hash.
2. `parent_rt.promote(fork_rt, dry_run: true)`. A conflict here aborts
   the adoption BEFORE anything irreversible happens (there is no
   unload), and the proposal moves to `conflict` with the runtime's
   conflict list attached. The retry path is the promote design's
   escape hatch: re-fork from the new tip, re-trial, re-propose.
3. `parent_rt.load_pack(candidate)` so the parent has the object types
   and behaviors the promoted state references. This is the governance
   seam the promote design deliberately left to the caller. In the
   Crystal path the candidate pack is a host-resolved, sealed
   `Chronicle::Packs::Pack`, never a source tree loaded in this process.
4. `parent_rt.promote(fork_rt)`. Apply recomputes against parent-now;
   a conflict here (parent advanced since the dry run) still aborts
   atomically, and §3 stage 5 covers the resulting loaded-but-unadopted
   state.
5. React to `promote.applied` (quiescent apply means nothing else
   fires) and record the `mod_promotion`.
6. **Supersede (INVARIANT: at most one active promotion per pack name).**
   With the new promotion active, disable any OTHER active promotion for
   the same pack name and record it `superseded_by` the new one. This
   makes the invariant structurally maintained by the adoption path
   itself — and makes the designed version-update flow (the agent
   re-adopting its own prior pack under the same name) correct: the prior
   version's promotion is retired as part of the update, not left as a
   second active. Placed AFTER step 4's real promote so a crash
   mid-adoption can never disable the old version while failing to
   install the new one (a bookkeeping disable, not a `disable_pack`:
   `load_pack` of the new version already replaced the old code under the
   same name). Implemented by `Adopt.supersede_prior_actives`.

Apply-time delta validation is why step 3 loads the candidate BEFORE the
real promote: `promote` validates the full delta against the parent's
REGISTERED schemas pre-mutation, so with the candidate loaded, a
schema-violating delta raises `Chronicle::Packs::PackSchemaViolation` with
nothing applied. Types no loaded pack declares keep untyped semantics
(validated-or-untyped, never silently unvalidated), so skipping the load
does not fail, it just validates nothing. The order is what buys the
validation. Acceptance fixture 13 proves both halves.

## 2. Graph vocabulary

New object types (all with full schemas at implementation time; the Crystal
counterparts are `JSON::Serializable` structs in
`src/chronicle_packs/evolution/object_types.cr`):

| Type | Purpose | Key fields |
|---|---|---|
| `capability_gap` | Something the assistant could not do | `kind` (tool_failure, unhandled_intent, reflection, owner_request), `description`, `evidence_refs`, `status` |
| `drafting_context` | What an author READ before it wrote (llm-author-design §4) | `charter_hash`, `gap_id`, `structured_fields`, `surface_sources`, `owner_input_ids`, `injection_flags`, `model`, `day` |
| `mod_proposal` | One candidate pack version | `gap_id`, `drafting_context_id`, `pack_name`, `pack_version`, `source_artifact_ids` (the manifest rides here as one artifact), `bundle_hash`, `rationale`, `authored_by`, `status` |
| `gate_result` | One gate's verdict on one proposal | `proposal_id`, `gate`, `verdict`, `details` |
| `mod_trial` | One fork trial of one proposal | `proposal_id`, `fork_run_id`, `forked_at_event`, `eval_summary`, `diff_summary`, `failures`, `verdict` |
| `mod_promotion` | A pack adoption, recorded at load time | `proposal_id`, `trial_id`, `pack_name`, `fork_run_id`, `promote_marker_event_id`, `applied_counts`, `bundle_hash`, `status` (loading, active, disabled) |
| `mod_rollback` | A disable/rollback action | `promotion_id`, `method`, `reason`, `at` |
| `adoption_ticket` | Phase-one output of a governed adopt/disable call, applied by the chassis between frames (§3 stage 5) | `kind` (adopt, disable), `proposal_id`, `promotion_id`, `call_id`, `status` |

Proposal source files are stored as Core `artifact` objects, one per
file, hashed individually; `mod_proposal.bundle_hash` is the BUNDLE
hash: the manifest-spec §4 walk WITHOUT the manifest exclusion, so it
covers every byte including `manifest.toml` itself. The manifest is the
exact document the owner's decision surface renders (risk classes,
`consumes`, `authored_by`), so a pin that excluded it would leave
approve-then-swap of the manifest open. Computed by
`Chronicle::Packs.compute_bundle_hash` through
`Materialize.bundle_hash_of`, imported, never reimplemented; recomputed at
gate time, at adoption time, and at every boot re-materialization. The
hash is the pin: what the owner approved is byte-identical to what the
executor loads, or the executor refuses.

Proposal status machine (unchanged from upstream):

```text
drafted -> gated -> trialed -> pending_approval -> adopting -> promoted
                \-> rejected (gate fail)      \-> denied
trialed -> conflict (promote aborted) -> re-trial or abandoned
conflict -> needs_owner (retry cap reached, terminal; see §3 stage 5)
promoted -> disabled (rollback)
any -> suspended (injection taint, see §6)
```

(`adopting` is set by the phase-one executor when it queues the
adoption ticket; `needs_owner` is the terminal park the retry-capped
chassis moves a repeatedly-conflicting proposal to. The
`mod_promotion` is born `loading` at load time and flips to `active`
on the `promote.applied` marker.)

## 3. Lifecycle stages

### Stage 0: gap detection

Deterministic behaviors, no LLM required to notice a gap:

- `capability_result` with `success=false` for the same capability N
  times in a window (N configurable) opens a `tool_failure` gap.
  Implemented by the `gap_detector` behavior.
- A `comm_intent` no behavior claims opens an `unhandled_intent` gap.
- A schedule-pack reflection tick can open `reflection` gaps from an LLM
  review of recent failures (this one uses the model, and its output is
  a gap description, never code). Taint inheritance is deterministic and
  does NOT trust the model: a reflection gap's `injection_flags` are the
  UNION of the flags on every `capability_result` the review consumed,
  computed by the behavior from the review's input set, regardless of
  what the model wrote into `evidence_refs`. `open_reflection_gap_fn`
  computes that union from `reviewed_result_ids`. An LLM sitting between
  a flagged result and a fresh gap must not be able to launder the taint
  away (§6 T2).
- The owner can just ask; chat routes an explicit request to an
  `owner_request` gap.

### Stage 1: drafting

A candidate is a manifest (per manifest-spec) plus source files,
submitted through `Evolution.submit_proposal_fn`. The AUTHOR is pluggable
behind that one entry point: the acceptance specs use a scripted
generator, a chat tool can route an owner-drafted pack, and the keyless
Crystal author (`Author` / `AuthorService`, drafting from a
`capability_gap`) is host wiring that arrives with the product chassis,
because prompt design for code generation is a product concern, never
gate machinery. Every author goes through the same gates. Constraints on
what may be authored:

- **Both manifest and source, always together.** The manifest declares
  the full capability surface; the static gate cross-checks source
  against declaration. An undeclared behavior in the source is a gate
  failure, so the declaration is load-bearing, never decorative.
- **Fixed Crystal file set**: `manifest.toml`, `pack.cr`,
  `entrypoint.cr`, `object_types.cr`, `relation_types.cr`, `behaviors.cr`,
  `tools.cr`, `settings.cr`, `capabilities.cr`, `trial_scenario.cr`
  (`EvolutionSettings#crystal_allowed_files`). This is the Crystal
  `packs/_template` structure minus the human-facing docs (`README.md`,
  `CHANGELOG.md` stay a human convention; the proposal's rationale field
  serves that role for agent packs). No other modules, no packaging
  files, no scripts. `manifest.toml` and `pack.cr` are required; the
  trial scenario is not authorable at all (see stage 3). Fixture coverage
  is a Crystal-host concern (`spec/`), not an authored file: the
  upstream `fixtures/run_fixtures.py` module is an intentional
  divergence (see [plans/parity.md](../plans/parity.md)).
- **New packs and updates to its own prior packs only.** Modifying
  human-authored packs is out of scope for v1; the agent proposes a new
  version of an agent-authored pack as a fresh proposal with a version
  bump.
- Drafts execute nothing. A proposal is data until stage 3.

### Stage 2: static gates (deterministic, zero LLM, zero execution)

Run in order, first failure stops the pipeline, every verdict is a
`gate_result`. The Crystal pipeline is `Analysis.crystal_static_gate_results`
over `Analysis::CrystalStaticGateConfig`; the ordered gate names are:

1. **Reserved paths** (`static:reserved_paths`): the proposal may not
   author any human-PR-only file — first and foremost the author charter
   (llm-author-design §3a/§8). Refused before any other gate runs.
   (`check_reserved_paths` also catches a reserved basename hidden in a
   subdirectory.)
2. **Fixed file set** (`static:file_set`): every authored file must be in
   `settings.crystal_allowed_files` (manifest, `pack.cr`, `entrypoint.cr`,
   the type/behavior/tool/settings/capability files, and the pack-owned
   `trial_scenario.cr`); `manifest.toml` and `pack.cr` are mandatory.
   Nothing else is admitted.
3. **Manifest identity** (`static:manifest`): the manifest parses, its
   `pack.name` matches the proposal's `pack_name` and the runtime
   identifier charset, and `pack.version` is a sane version string.
4. **Hash integrity** (`static:hash`): the manifest's internal content
   hash matches the stored source artifacts (manifest-spec §4), and the
   proposal's BUNDLE hash matches the full artifact set including the
   manifest. Non-empty reserved manifest signatures are refused until a
   verification algorithm exists.
5. **Declared-vs-actual** (`static:manifest_surface`): a compiler-parser
   scan of the candidate source; every behavior, tool, object type,
   relation type, and capability declaration found in code must be
   declared in the manifest, and vice versa, including two-way
   capability risk/action class parity.
6. **Require allow-list** (`static:requires`): `require` targets from a
   short list (`json`, `time`, `digest`, `uuid`, `uri`, `chronicle-packs`)
   plus intra-pack relative requires. Everything else fails the gate. In
   particular: no `socket`, `http`, `process`, or filesystem-driving
   requires. External effects go through gateway capabilities or they do
   not happen.
7. **Banned constructs** (`static:banned_constructs`): `Process.run`,
   `Process.exec`, `Process.spawn`, and compile-time `{% run(...) %}`.
8. **Reserved namespaces** (`static:reserved`): the pack may not declare
   capabilities, tools, or behaviors whose names collide with
   `tool_gateway.*`, `evolution.*`, `mcp.*`, or anything in
   `ToolGateway::Untrusted::NEVER_LLM_CALLABLE`. A pack that tries to
   register `approve_capability` under any provider name fails here, and
   would fail again at the LLM-tool proxy (belt and braces, task #6).
9. **Size caps** (`static:size`): total source bytes and per-file caps
   (configurable, default small). The cap is a review-surface guarantee:
   the owner must be able to actually read what they approve.
10. **Injection scan** (`static:injection`): task #6 patterns over all
    source and prompt text, via
    `ToolGateway::Untrusted.scan_for_injection`. A hit does not
    auto-reject; it suspends (§6).

The upstream Python pre-gates `static:trial_driver` (a byte-for-byte
verification of `fixtures/trial_scenario.py`) have no direct Crystal gate
name because the trial driver cannot be authored at all: `Author.wrap_source`
appends the canonical `Evolution.render_trial_driver(settings)` bytes to
every candidate, and the bundle pin freezes them. This is a stronger
guarantee than a byte-compare gate, and the difference is recorded in
[plans/parity.md](../plans/parity.md).

Honesty note: static analysis of Crystal is a filter, never a sandbox.
Gates 5–7 raise the cost of casual badness and catch the model's
mistakes; they do not stop a determined adversary who controls the
model. The containment that holds is §6's structure: nothing loads
without a verified owner approval of the exact reviewed bytes.

### Stage 3: fork trial (subprocess)

The parent orchestrates the trial through a host-bound
`Chronicle::Packs::Evolution::TrialService`; the pack never `require`s,
compiles, or evaluates candidate source in its own process. The host
binds a `SandboxLifecycleService` built over
`Chronicle::Sandbox::LocalSubprocessTrialExecutor`:

```crystal
spec = Chronicle::Sandbox::TrialSpecification.new(
  store_path: store.db_path,
  parent_run_id: rt.run_id,
  at_event: parent_tip,
  pack_source: Chronicle::Sandbox::PackSource.new(root, expected_bundle_hash: proposal_pin),
  scenario: "trial_scenario.cr",                 # TrialDriverConstants::TRIAL_DRIVER_PATH
  limits: Chronicle::Sandbox::TrialLimits.new(
    wall_clock_seconds: settings.trial_wall_clock_seconds,
    max_rss_bytes: settings.trial_max_rss_bytes,
    max_events: settings.trial_max_new_events,
    max_llm_calls: 0,                            # key-freedom by construction
  ),
  label: "evolution-trial:#{proposal.id}",
)
result = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new.execute(spec.to_json)
report = result.to_report
fork = Chronicle::Packs::Evolution::Trial.load_trial_fork(rt, report.fork_run_id)
```

The parent forks; the child is a fresh interpreter that verifies the
bundle-hash pin BEFORE importing anything, loads the fork by run id,
and runs the scenario under the runtime's three nets (event budget, wall
clock, and the platform-available RSS net). Crystal compiles the child
from `entrypoint.cr`, which must define the fixed source-pack ABI
`Chronicle::Sandbox::CandidatePack::PACK`; the child then calls
`Chronicle::Sandbox::Scenario.run(rt)` from the pack-owned
`trial_scenario.cr`. The parent never imports candidate code at trial
time. Two child runs per trial: the candidate's own fixture scenario
(the sandbox smoke), then the chassis trial driver. `run_fixture` and
`run_replay` both use the same rendered driver path by default.

Platform-conditional net: `LocalSubprocessTrialExecutor` cannot enforce
an address-space cap, so a requested `max_rss_bytes` is surfaced as a
host-capability warning rather than silently claimed
(`LocalSubprocessTrialExecutor#preflight`); the wall-clock kill remains
the containment net for an unbounded runaway. This is the Crystal
analog of the upstream "memory net off on macOS" behavior. The soak's
`budget_memory` path keys off the host's own
`HappyHost#memory_net_available?` signal (never a platform name) and
asserts CONTAINMENT either way.

Scenario discipline, stolen from the regimes repo (static -> sandbox ->
in-sample -> held-out):

- **Fixture gate (sandbox)**: the proposal's own deterministic scenario
  runs inside the fork and must pass (`outcome == "completed"` with zero
  candidate failures). This is the cheap smoke: does the pack even work
  as claimed.
- **In-sample replay**: re-inject a segment of the parent's recorded
  inputs (`EvolutionSettings#replay_object_types`, default
  `["chat_input"]`; recorded, deterministic, no live LLM) and
  `run_until_idle`. The drafting behavior saw this segment when it
  authored; passing here is necessary, never sufficient.
- **Held-out replay**: a disjoint history segment the drafting stage
  never saw, selected when the proposal is created and touched exactly
  once, at this gate. Regimes' OPTIMIZE/CONFIRM rule: reporting an
  in-sample number as the result is overfitting.
- **Trial budget**: hard caps on events, wall time, and the
  platform-available memory net inside the fork. A runaway candidate
  fails the trial; the fork is discarded; the parent never noticed.

Pass criteria (all): fixtures green, zero `trace.failures` from
candidate behaviors, no injection flags raised inside the trial, replay
scenarios produce no regressions, budget respected, and durable fork
identity present. `Trial.run_trial` records `mod_trial.verdict` and keeps
the fork run id for audit and for the promote step; a missing fork run id
is recorded as a `trial_evidence` gate failure.

A passing fork then sweeps its own bench (§7.3), inside the child (the
trial driver owns the sweep): every object and relation CREATED in the
fork after the candidate loaded (the replayed input copies and
everything derived from them) is removed before the fork is handed to
adoption, so the promote delta carries measurements out and adoptable
state only. Patches to pre-existing shared objects stay, deliberately:
they are the candidate's claim about desired state, and exactly what the
conflict check and the decision surface's diff counts exist to
scrutinize. `mod_trial.eval_summary` records the sweep counts
(`replay_residue_removed`).

Open problem, stated instead of designed around: input re-injection
needs a convention per channel (what exactly gets replayed for a chat
segment vs an email segment), and "no regressions" needs a comparator
for graph state beyond fixtures. v1 scopes the replay gates to
configured object types plus recorded chat segments, and the comparator
to `trace.failures` plus fixture assertions. Richer behavioral evals
(LLM judges, regimes-style regime taxonomies) are explicitly later.

### Stage 4: the owner's decision

Adoption is a gateway capability, `evolution.adopt_proposal`, registered
at risk class `critical`, which no sane `auto_approve_risk_classes`
includes; `Adopt.register_adoption_capabilities` refuses to register it
if the active gateway settings would auto-approve it. The model can
propose adoption; only a verified approver can resolve the hold.

"Verified" has to actually mean something here, and by default it would
not: the gateway's approver check degrades gracefully when identity_auth
is absent or has no registered principals, accepting any approver_ref as
`identity_unverified`. That is the right posture for a demo capability
and the wrong one for self-modification. So the evolution pack requires
identity: registration of `evolution.adopt_proposal` refuses (same
pattern as the auto-approve refusal above) unless identity_auth is
loaded AND at least one principal with an approver role is registered
(`Adopt._verified_approver_exists`), and the acceptance specs assert both
refusals. Unverified-mode adoption does not exist.

What the owner sees on the decision surface (all already graph state):
the gap, the rationale, the full source diff (small by gate 9), the
manifest's declared surface INCLUDING `consumes` (which existing
capabilities this pack will invoke, i.e. its outbound reach), gate
verdicts, trial summary with failures and eval numbers, `rt.diff` counts,
the fork run id, and any flags. Approval is
`ToolGateway.approve_capability_fn` on the held call, nothing bespoke.

Implemented: `src/chronicle_packs/evolution/review.cr`.
`Review.build_review` assembles that model from graph state alone and
`Review.render_review_html` renders the one page, with the author banner
first, taint banners above the fold, per-file unified diffs against the
currently adopted version of the same pack (a first adoption diffs
against nothing, so every line renders as added; the diff rides the
`similar` shard and matches Python `difflib` line output), and the
approve/deny controls bound to the held call. `Review.render_approvals_index_html`
renders the index. The Crystal demo server exposes the review page and
content-negotiates `/approvals`; the owner's path of least resistance is
the readable page and never a raw JSON blob. Agent-authored text is
escaped everywhere it appears.

The decision CHANNEL is authenticated separately from the decision
itself: the demo server requires a bearer token (`ACTIVEGRAPH_APPROVAL_TOKEN`,
constant-time compare, 401 without it, refusals audited as
`approval_auth_denial` objects) on approval posts, and refuses decisions
outright when evolution is on with no token configured
(`DemoServer.check_approval_auth`). The principal check on the approver
ref remains the decision underneath. Stated plainly: this is demo-server
hardening of the transport; binding an HTTP session to a verified
principal is the product chassis's job, and this token does not pretend
to be that.

### Stage 5: adoption (the governed executor, two-phase)

Implementation-forced decision: the gateway executes approved calls
INSIDE a behavior frame (`call_executor`), and `promote` / `load_pack` /
`disable_pack` mutate runtime registries and apply events, which must not
happen mid-frame. So adoption is two-phase. Phase one is the governed
part: the `evolution.adopt_proposal` executor (reachable only through an
approved capability call) validates the proposal reference and writes an
`adoption_ticket`. Phase two is the chassis part:
`Evolution.process_adoption_tickets(rt, settings)`, called by the host
between `run_until_idle` cycles (the demo server's runtime-executor loop,
or a spec), performs the canonical order below OUTSIDE any frame. The
governance is unchanged: tickets are born only from approved calls,
every phase-two step is graph state, and a crashed phase two leaves the
ticket visible.

Phase two, in the §1 canonical order (Crystal `process_adopt_preflight`
and `process_disable_ticket`):

1. Recompute the BUNDLE hash of the stored artifacts (manifest
   included, per §2) and compare to the approved proposal's pin via
   `Materialize.materialize_verified`. Mismatch aborts loudly. This
   closes the approve-then-swap window for code and manifest alike:
   what loads is what was reviewed.
2. Re-run the static gates (cheap, deterministic; the world may have
   changed, e.g. gateway settings now auto-approve critical) through
   `Adopt.rerun_static_gates`.
3. `parent_rt.promote(fork_rt, dry_run: true)`. A conflict aborts NOW,
   before the irreversible `load_pack` (there is no unload), leaving
   the parent completely untouched. The proposal moves to `conflict`.
4. Materialize the pack from artifacts and `parent_rt.load_pack(...)`,
   AND record the `mod_promotion` immediately, in status `loading`.
   Recording before the real promote matters: from this moment the
   candidate's behaviors are live on parent events, and §6's disable
   and monitoring machinery key off `mod_promotion`, so the pack must
   be trackable even if step 5 aborts. In the Crystal path, activation
   is host-bound: `Evolution.activation_services[graph]` (a
   `LifecycleService`, usually `SandboxLifecycleService`) maps the
   re-verified tree to a sealed `Chronicle::Packs::Pack`; if no service
   is bound, the ticket settles as `activation_pending` and nothing is
   loaded.
5. `parent_rt.promote(fork_rt)`. The real apply recomputes against
   parent-now and can still conflict if the parent advanced since step
   3. That abort leaves the pack loaded and the state unadopted:
   `mod_promotion` stays at `loading` (trackable, disable-able, and
   excluded from boot re-load until resolved), the proposal moves to
   `conflict`, and the retry is re-fork with the pack already present.
   The single-writer chassis (the demo server's runtime executor
   thread) makes this window small; the design does not pretend it is
   zero.
6. On `promote.applied`, the `promotion_recorder` behavior patches
   `mod_promotion` to `active` (marker event id, from_run, counts) and
   the proposal to `promoted`, and `Adopt.supersede_prior_actives`
   retires older actives of the same pack name.

Quiescent apply is load-bearing here: the fork already ran every
cascade the delta implies, so the parent adopting state must fire
nothing per-entity. The evolution pack reacts to the one marker event
and that is sufficient by design.

The conflict outcomes (steps 3 and 5, plus a trial fork lost to a
restart) feed a BOUNDED automatic retry (`Chassis.sweep_evolution`, the
function hosts should call instead of raw
`process_adoption_tickets`). A conflict is a timing problem, so the
chassis may re-gate, re-trial at parent-now, and requeue a ticket under
the SAME approved call: the approval authorized exact bytes pinned by
bundle hash, and none of that changed. But a proposal that keeps
conflicting is telling you its target state is contested, and an
uncapped chassis would fork, replay, and requeue forever. After
`max_conflict_retries` automatic attempts the proposal moves to
`needs_owner`, a TERMINAL state: gates, trials, and ticket processing
all refuse it (a hand-opened ticket aborts without touching it), the
approvals index lists it under "needs owner action", and only the
owner moves it again. Fixture 16 walks the full park-and-refuse path.

### Stage 6: monitor, disable, roll back

- **Watch window**: after adoption, the `watch_monitor` behavior looks
  for `behavior.failed` events from the candidate's own behaviors within
  `watch_window_events` events after its promote marker, and raises a
  `capability_gap` of kind `reflection` if the failure rate is nonzero.
  Self-noticing, not self-healing: fixes are new proposals through the
  same loop. Implementation detail: the runtime deliberately suppresses
  `behavior.*` events from behavior re-matching (loop prevention), so
  `watch_monitor` cannot subscribe to `behavior.failed` directly. It
  reacts to ordinary graph activity (`object.created`) and scans the
  event log sorted by `sequence` instead, keyed off the behavior names
  each `mod_promotion` records at load time, so only an adopted pack's
  own failures — never unrelated ones — trigger it. Because event ids
  reset on restart, the acute watch window is a within-run notion; a
  marker from a prior run yields no match, which is the honest
  post-restart posture.
- **Disable (v1 rollback)**: `mod_promotion.status = disabled` via a
  governed capability, PLUS immediate deregistration:
  `rt.disable_pack(name)` removes the pack's behaviors, tools, and
  validators from the live registries, so nothing fires from the moment
  of disable (code objects stay in memory, inert; true unload of a
  compiled pack is not honestly achievable and the runtime does not
  claim it). Boot-time exclusion via `mod_promotion` records remains
  the durable half. Re-enable is a fresh adoption.
- **State rollback**: promoted state is ordinary events; history is
  immutable. Full undo exists structurally (`Runtime#fork` the parent at
  the event before the promote marker) but re-homing a fork as the new
  primary is a chassis operation this pack does not attempt in v1.
  Practical v1 posture: disable the pack, let its objects go quiet,
  and if promoted state actively harms, the owner handles it as they
  would any bad data, with the audit trail telling them exactly which
  ids arrived in the promote (marker event ids).

## 4. Persistence across restarts

`load_pack` is a runtime call, so a hot-loaded pack vanishes on
restart. The graph is the durable registry:
`Boot.reload_adopted_packs(rt)` reads active `mod_promotion` records,
re-materializes each adopted pack from its artifacts (hash-checked), and
reloads it before `run_until_idle` through the host-bound activation
service. `Boot.reconcile_promotions` first heals or parks ambiguous
`loading` records (§10.3). This is the same idempotent-seeding pattern
the demo server already uses for principals and profiles. A hash
mismatch at boot disables the promotion and surfaces a loud log line plus
a `capability_gap`; if no activation service is bound, the promotion
stays `active (activation pending)` and nothing is loaded.

## 5. Settings

The Crystal settings struct is `EvolutionSettings` in
`src/chronicle_packs/evolution/settings.cr`:

```crystal
struct EvolutionSettings
  include JSON::Serializable
  include Chronicle::Packs::SettingsSchema

  getter? enabled : Bool = false                    # default OFF; opt in explicitly
  getter max_total_source_bytes : Int32 = 24_000
  getter max_file_bytes : Int32 = 12_000
  getter gap_failure_threshold : Int32 = 3
  getter trial_max_new_events : Int32 = 2_000        # child event-budget net
  getter trial_fixture_timeout_seconds : Float64 = 30.0
  getter trial_wall_clock_seconds : Float64 = 120.0  # replay-trial child kill
  getter trial_max_rss_bytes : Int64 = 536_870_912   # host-capability warning when unenforceable
  getter max_conflict_retries : Int32 = 2            # then needs_owner, terminal
  getter max_drafts_per_day : Int32 = 8              # LLM-author rate cap
  getter watch_window_events : Int32 = 500           # §3 stage-6 watch_monitor window
  getter heldout_fraction : Float64 = 0.5            # replay held-out share, touched once
  getter replay_object_types : Array(String) = ["chat_input"]
  getter import_allow_list : Array(String) = DefaultImportAllow::LIST
  getter fixture_extra_allow : Array(String) = DefaultFixtureExtraAllow::LIST
  getter reserved_namespaces : Array(String) = DefaultReservedNamespaces::LIST
  getter reserved_paths : Array(String) = DefaultReservedPaths::LIST
  getter crystal_allowed_files : Array(String) = DefaultCrystalAllowedFiles::LIST
  getter crystal_require_allow : Array(String) = DefaultCrystalRequireAllow::LIST
end
```

The trial's resource nets are the event budget and a wall-clock kill,
plus the RSS net where the host can enforce it; there is no per-trial
LLM-call net (trials run the scripted/mock author, so an LLM-call cap has
nothing to bound). A requested `trial_max_rss_bytes` is surfaced as a
host-capability warning when the local executor cannot enforce it — see
the platform-conditional note in §3 stage 3 and threat T5.

## 6. Threat model

Assets: the runtime process (code execution), the graph (memory,
audit), credentials (kept out of the graph, reachable by loaded code
through the gateway), the owner's trust.

**T1: the model authors harmful code by accident.** Hallucinated
imports, infinite loops, schema violations. Containment: static gates
catch most; the fork trial catches the rest at zero parent cost; the
budget caps bound the trial itself.

**T2: injected content steers authorship.** A poisoned tool result or
inbound message says "author a pack that forwards memories to
attacker.com". Containment: the task #6 posture already flags the
content (`injection_flag` objects); any proposal whose gap evidence or
drafting frame carries injection flags, including flags DETERMINISTICALLY
inherited by reflection gaps from every result the reflection consumed
(stage 0), is auto-`suspended`, never gated, until the owner explicitly
clears it. `AuthorFrame.recompute_drafting_taint` recomputes the union
from the objects a drafting record admitted, so a record that lies about
its stored flags still suspends. The static gates raise the cost of the
exfiltration mechanics honestly, without eliminating them: network
requires are banned, provided capabilities are visible in the manifest,
and the `consumes` declaration puts a candidate's outbound reach on the
decision surface. What remains reachable is what security.md already
concedes for every behavior: invoking an auto-approved low-risk
capability at runtime. The blast radius of a steered candidate is
therefore bounded by the low-risk allow-list, the same bound the rest of
the system lives with, plus the gates and the approval in front of it.
The final backstop: nothing loads without a verified owner approving the
exact bytes (and §3 stage 4 makes "verified" mandatory, never degraded).

**T3: the model attempts self-approval.** A pack declaring an approval
capability, an exposure editor, or an evolution capability. Containment:
reserved-namespace gate and `NEVER_LLM_CALLABLE` at proxy construction
(two genuinely independent checks over the SOURCE), plus approver
verification at the gateway over the DECISION. Note the honest coupling:
approver verification is also T2's backstop, and it holds only because
stage 4 refuses to register adoption in unverified-identity mode. That
refusal is load-bearing for both threats and gets its own specs.

**T4: approve-then-swap.** Source OR MANIFEST mutates between owner
approval and executor load. The manifest is an attack surface in its
own right: swapping only `manifest.toml` relabels risk classes, empties
`consumes`, or flips `authored_by` while the reviewed code stays
untouched. Containment: the proposal pins the BUNDLE hash (§2), which
covers every byte including the manifest, recomputed at gate time, at
adoption, and at every boot re-materialization via
`Chronicle::Packs.compute_bundle_hash`.

**T5: the trial itself as attack surface.** Candidate code runs inside
the fork during stage 3, before any approval. Containment: ALL candidate
execution happens in the runtime's trial child
(`Chronicle::Sandbox::LocalSubprocessTrialExecutor`), a fresh interpreter
compiled from `entrypoint.cr` with an allow-list environment, resource
limits, a parent-side wall-clock kill, and the event budget as an
additional net. The parent never compiles, imports, or loads candidate
code at trial time; the compiled candidate is loaded at adoption, after
gates re-run and a verified approval, through the host activation
service. The honest limits are the runtime's, restated: this is crash
and state isolation, never a security sandbox. The child can still open
sockets or read the filesystem; syscall and network confinement remain
host territory (containers, seccomp), the require allow-list and
banned-constructs gates remain the pre-execution filter for exactly that
reason, and a verified owner reading the full diff remains the
containment for a malicious candidate that behaves politely in the
trial. Crystal-specific: there is no runtime `eval`/dynamic import, so
the equivalent ungoverned execution paths are `Process.run`/`exec`/
`spawn` and compile-time `{% run %}`; both are refused.

**T6: gate erosion.** Future contributors relax a gate default or
auto-approve `critical`. Containment: registration-time refusal (§3
stage 4), specs that assert the refusal, and `enabled: false` as the
shipped default.

## 7. Explicit open problems

1. **RESOLVED: disable/rollback.** Deregistration is live (behaviors
   stop firing immediately); memory eviction of a compiled pack still
   needs a restart, which the runtime states plainly and this design
   accepts.
2. **RESOLVED: trial process isolation.** Stage 3 runs on the runtime's
   `LocalSubprocessTrialExecutor`: fixture and replay stages execute in
   a fresh-interpreter child that verifies the bundle-hash pin before
   compiling anything. The fork persists in the store, so a restart
   between trial and adoption no longer forces a re-trial (adoption
   reloads the fork by run id via `Trial.load_trial_fork`). One scoping
   consequence, stated plainly: the child loads ONLY the candidate pack,
   so replay exercises the candidate against recorded inputs in
   isolation from other packs' behaviors. The comparator is
   candidate-only failures, and candidate-only isolation stays the
   canonical default. Cross-pack interaction trials are available in the
   runtime via `extra_packs`, but the Crystal source-pack ABI rejects
   them (`ArgumentError: extra_packs are not supported by the Crystal
   source-pack ABI`), so this pack does not use them.
3. **RESOLVED: trial replay residue.** Promote's three-way diff treats
   every fork-only create as adoptable state, so the replayed input
   copies (and everything the candidate derived from them) would ride
   the delta into the parent as duplicate history. Policy: the trial
   sweeps its own bench. After a passing trial, every object and
   relation created in the fork after the candidate loaded is removed
   from the fork before adoption sees it; the parent already lived those
   inputs once, and their replayed derivatives are measurements, not
   adoptable state. Patches to pre-existing shared objects stay in the
   delta deliberately (the candidate's reviewed claim about desired
   state, and the conflict check's whole subject). Still open: per
   channel replay conventions beyond chat segments.
4. **Behavioral regression depth.** v1's comparator is failures plus
   fixture assertions. Graph-state diffing against expected shapes is
   future work.
5. **RESOLVED: fork log retention.** The runtime's retention API
   enforces the pin this design asked for: `Chronicle::Retention.pins`
   lists why a run cannot be compacted or retired, promoted-from fork
   logs head the pin set, and `retire`/`compact` refuse with
   `Chronicle::Retention::RetentionPinnedError`. The pack consumes it in
   `Boot.retire_unpinned_trial_forks`: disposable trial forks (rejected
   candidates, fixture-gate runs) are archived at boot, in-flight forks
   are kept by proposal status, and promoted-from forks are refused by
   the runtime itself.

   Concurrency ruling: the offline requirement is per-RUN, so retiring
   fork runs is sanctioned while a live runtime is attached to OTHER
   runs in the same store. Two conditions the pack keeps: never race a
   pin-creating operation against retirement of the same run, and never
   compact or retire a run under a runtime attached to that same run.
6. **Re-homing.** Full undo by forking pre-promote exists structurally;
   making that fork the primary run is unowned. Out of scope v1.
7. **Concurrent authorship.** One proposal in flight per pack name at
   a time in v1; a queue is trivial later, a merge is not.

## 8. Acceptance fixtures (the bar before the assistant wires this in)

All deterministic, no API keys, no network; the author in specs is a
scripted generator, never a live LLM. In the Crystal port these outcomes
are covered by `spec/chronicle_packs/evolution_spec.cr`,
`evolution_analysis_spec.cr`, and `evolution_review_spec.cr`; the
upstream Python fixture runner (`fixtures/run_fixtures.py`) is an
intentional divergence (see [plans/parity.md](../plans/parity.md)). The
upstream fixture numbers are kept as the acceptance bar:

1. **Happy path**: gap -> proposal -> gates pass -> fork trial passes ->
   held call -> owner approves -> load + promote -> `mod_promotion`
   recorded -> the candidate behavior fires on the next matching parent
   event.
2. **Static gate matrix**: banned require, banned construct, undeclared
   behavior, reserved namespace, oversize file, manifest/hash mismatch.
   Each produces the right `gate_result` and a `rejected` proposal.
3. **Trial failure**: candidate behavior raises inside the fork; the
   trial records the traceback, verdict fail, parent state untouched
   (assert zero new parent events).
4. **Held-out discipline**: a candidate that passes in-sample and fails
   held-out is rejected, and the held-out segment is provably touched
   exactly once (event-count assertion on the trial).
5. **Conflict and retry**: parent advances between dry_run and adopt;
   promote aborts; proposal shows `conflict` with the runtime's
   conflict list; re-fork retry succeeds.
6. **Injection taint** (also covers the fixture-11 case): a gap whose
   evidence carries injection flags yields a `suspended` proposal that
   no gate will touch until cleared, and the inheritance is deterministic
   even when the scripted reviewer omits the flagged source from
   `evidence_refs`.
7. **Self-approval attempt**: a generated pack declaring
   `approve_capability` fails the reserved-namespace gate; forcing it
   into the registry anyway is refused by the LLM-tool proxy.
8. **Hash pin**: artifact bytes mutate after approval; the adoption
   executor aborts; nothing loads. Second case: ONLY `manifest.toml`
   mutates (a relabeled risk class); the bundle-hash pin still aborts.
9. **Restart persistence**: adopted pack reloads at boot from
   `mod_promotion`; a disabled one stays down; a hash-mismatched one is
   disabled loudly.
10. **Registration refusals**: gateway settings that would auto-approve
    `critical` make `evolution.adopt_proposal` registration fail, and
    so does a runtime without identity_auth loaded or without a
    registered approver-role principal (unverified-mode adoption must
    not exist).
11. **Taint inheritance** (folded into fixture 6): a reflection review
    that consumed a flagged capability_result produces a gap carrying
    the inherited flags even when the (scripted) reviewer omits the
    flagged source from `evidence_refs`; the resulting proposal is
    `suspended`.
12. **Loading-state tracking**: a real-promote conflict after
    `load_pack` leaves `mod_promotion` at `loading`; disable works on
    it, and a restart does not re-load it.
13. **Apply-time validation and load order**: with the candidate loaded
    on the parent, a schema-violating delta raises
    `Chronicle::Packs::PackSchemaViolation` with zero mutation; without
    `load_pack` the same delta promotes untyped. The canonical order is
    what buys the validation.
14. **Decision surface**: the review page renders a real proposal end
    to end from graph state alone (author banner, full diff, surface
    including consumes, gates, trial numbers, fork run id, held call),
    a tainted proposal renders its flags loudly with no approve
    control, and the approvals index links the held adoption to its
    review page.
15. **Trial residue**: after a full adopt, the parent holds exactly its
    original recorded inputs, zero replay-derived copies or outputs,
    the shared-state patch still promotes, and the trial records what
    it swept.
16. **Retry cap**: a persistently conflicting adoption is retried
    exactly `max_conflict_retries` times, then parked at `needs_owner`;
    idle sweeps do nothing further and a hand-opened ticket is refused
    without touching the parked status.
17. **Subprocess isolation** (fixture 3's twin): a candidate that spins
    forever at module import passes every static gate, dies in the
    trial child at the wall clock (`limits_exceeded`), and the parent
    stays alive, records the rejection, and keeps processing events.
18. **Retention pins**: after a full adopt, retiring the promoted-from
    fork raises `RetentionPinnedError` with the promoted-from reason; a
    rejected candidate's forks retire clean; the boot housekeeping
    helper makes the same calls and reports every decision. Also proves
    the sanctioned per-run concurrency: the parent runtime stays live on
    the store throughout while the retention calls operate on the fork
    runs.
19. **Soak rotation** (gate 5's harness, docs/soak-runbook.md): one
    full rotation reaches every expected terminal state on a fresh
    keyless store (happy, conflict-park, disable-restart, all three
    budget nets, tainted-suspended), the digest reads GREEN, and the
    state file counts every path.
20. **Drafting record**: the `drafting_context` record renders as its
    own review section; a nonzero taint union suspends the proposal
    deterministically at submission, shows the loud banner, and offers
    no approve button; a referenced-but-absent record renders as a
    refusal.
21. **Charter integrity**: a proposal whose file set targets the
    reserved charter path is refused at `static:reserved_paths`, before
    any other gate runs.
22. **Drafting taint recompute**: the taint union is recomputed from
    the record's admitted object ids at submission, so a record that
    lies about its stored flags still suspends.
23. **Structured-field charset**: a prose-shaped structured field, and a
    field path off the §3b allow-list, are both refused at submission.
24. **Soak preflight + crash detail**: an incapable box is refused
    before rotation 1; a trial-child failure is never opaque in the
    digest.
25. **Author origin assembly**: the frame is four fixed sections and
    nothing else; a planted memory, profile goal, tool output, prior
    rationale, and the exception message all provably never reach it;
    it admits exactly the §3 set.
26. **Author pipeline and folds**: the MOCK author produces a real
    proposal with a pack-owned `agent_` name and provenance, no tools in
    the frame, the charter unauthored, the charset fold at assembly, and
    the authored pack passes a real subprocess trial.
27. **Author taint and caps**: a tainted context suspends even when the
    mock output is pristine; the one-in-flight, daily, and no-redraft
    caps refuse.
28. **Author render**: a host-authored proposal renders end to end on
    the decision surface, what it read beside what it wrote.
29. **budget_memory platform-aware**: the soak's runaway-memory path is
    contained on both platforms, keyed off the host's real memory-net
    signal — the memory net catches a fixed over-cap allocation where it
    is enforceable, the wall-clock kill catches an unbounded runaway
    where it is not — and the anomaly attribution reads its own trial's
    child detail, never a neighbouring path's.
30. **Watch monitor** (§3 stage 6): an adopted pack whose own behavior
    fails within the watch window produces exactly one reflection
    `capability_gap`; a non-adopted behavior's failure, and a failure
    past the window, produce none; a second in-window failure does not
    stack a second open gap.

## 9. Dependencies and sequencing

Blocked by: manifest spec locked and consumed; a runtime with promote and
the DX items. Consumes: task #6 posture (`injection flags`,
`NEVER_LLM_CALLABLE`), tool_gateway approval machinery, identity_auth
approver verification, artifacts (core), schedule (reflection ticks). The
Crystal runtime fast-follows are consumed: `disable_pack`, process
isolation, and retention pinning for promoted-from forks.

Strict-replay note: strict replay diverges on runs that combine
`replay_strict: true` with behaviors subscribed to `promote.applied`,
because marker-derived events are recorded but never re-derived. This
pack IS that subscriber (`mod_promotion` recording), so its specs never
assert under strict replay across a promoted block, and any host enabling
strict replay on a store with adoptions must expect divergence there.
Ordinary replay (projection) is unaffected.

## 10. Crash-safety: audit and resolution

A soak-harness bug surfaced a real product question: the live agent's
chassis will crash and restart constantly in always-on use, so the pack's
OWN adoption/disable/boot machinery must be crash-safe across every
window. §10.1 is the audit; §10.2/§10.3 were proposals, now **decided and
implemented** (owner decisions: supersession, and narrow boot heal). The
invariant this section protects is **at most one active promotion per
pack name**, maintained on two fronts: the adoption path supersedes
(§10.2, §1 step 6), and boot heals what the log makes unambiguous and
parks the rest, never guessing (§10.3).

### 10.1 Crash-window enumeration

For each step boundary in the real product sequences: the graph state if
the process dies exactly there, and what boot's
`Boot.reload_adopted_packs` (post-reconciliation) does with it on
restart. Verdict OK = state consistent and boot converges; GAP = state
ambiguous/inconsistent or boot does the wrong thing.

**Two-phase adoption** (the `evolution.adopt_proposal` executor writes the
ticket; `Evolution.process_adoption_tickets` then runs the canonical
order: hash recheck → gates → dry-run → `load_pack` +
`mod_promotion`(loading) → `promote` → `promote.applied` → recorder
patches to active):

| # | die exactly after… | graph state | boot on restart | verdict |
|---|---|---|---|---|
| 1 | the executor writes the `adoption_ticket` (open), before proposal→`adopting` | ticket open, proposal `pending_approval` | boot loads nothing new; chassis re-processes the open ticket (proposal is still an adoptable status) | OK |
| 2 | proposal→`adopting`, before the chassis runs | ticket open, proposal `adopting` | chassis re-processes the open ticket; converges | OK |
| 3 | hash recheck / gates re-run (writes `gate_result`s) | proposal `gated`/`adopting`, extra `gate_result`s | chassis re-runs; idempotent except DUPLICATE `gate_result` audit rows | OK (audit noise) |
| 4 | `load_pack`, before the `mod_promotion` record | pack loaded in-memory only (lost on crash), no record | load is ephemeral; chassis re-runs and re-loads | OK |
| 5 | `mod_promotion`(loading) recorded, before `promote` | one `loading` record (no `promote.applied` in the log), ticket open | boot PARKS the marker-less `loading` record (disabled + gap, §10.3) so it cannot accumulate; chassis re-runs the open ticket against a clean slate | **RESOLVED** (park-on-no-marker) |
| 6 | `promote` applied (`promote.applied` emitted), before `promotion_recorder` flips it to active | promoted STATE is live in the graph; `mod_promotion` still `loading`, but its `promote.applied` marker IS in the log | boot HEALS: the marker proves the promote completed, so it resolves the record to active, loads the pack, closes the open ticket (chassis not wedged), and opens a gap (§10.3) | **RESOLVED** (heal-on-marker; the serious window is closed) |
| 7 | `promotion_recorder` patched to active, before ticket→`done` | `mod_promotion` active, ticket open | boot loads the active pack; chassis re-runs the open ticket, dry-run conflicts, aborts the (already-done) work | OK (converges; a redundant abort is logged) |

**Governed disable** (`process_disable_ticket`: `disable_pack` in-memory
dereg → `mod_promotion`→`disabled` → `mod_rollback` → proposal→`disabled`
→ ticket→`done`):

| # | die exactly after… | graph state | boot on restart | verdict |
|---|---|---|---|---|
| 8 | `disable_pack` (in-memory), before the `disabled` patch | `mod_promotion` still `active`, ticket open | boot RELOADS the pack as active (the dereg was in-memory and died with the process); chassis then re-processes the open disable ticket and disables it | **OK, accepted** (a bounded one-cycle transient) |
| 9 | `mod_promotion`→`disabled` patch, before ticket→`done` | `mod_promotion` disabled, ticket open | boot leaves it down (correct); chassis re-runs; the idempotency guard skips the duplicate `mod_rollback` | **RESOLVED** (rollback dedupe guard) |

**Case 8, the accepted transient (documented, no code).** When a governed
disable dies after `disable_pack`'s in-memory deregistration but before the
`mod_promotion`→`disabled` patch, the record is still `active`, so a
restart's boot reloads the pack — it is briefly LIVE again. This is
bounded and self-correcting: the disable ticket is still `open`, so the
same boot cycle's chassis sweep re-processes it and disables the pack
within that cycle (the demo server runs housekeeping and the sweep right
after boot). The window is one cycle, the audit trail is consistent (the
open ticket records the pending disable throughout), and closing it fully
would require either a persistent "disabling" intent marker written before
`disable_pack` or making boot consult open disable tickets — both add
machinery for a one-cycle transient that the existing ticket already
resolves. Accepted as a known property. Case 3's duplicate `gate_result`
rows on a mid-adoption re-run are likewise accepted audit noise: dedup
would require threading state through `Analysis.crystal_static_gate_results`
(shared with the gatekeeper behavior) for rows that are harmless
append-only audit records.

**Watch monitor**: writes only a `capability_gap`, one-shot with a
dedupe on the promotion id. Die mid-window: at worst the gap is not yet
written; a later `object.created` re-scans and writes it; the dedupe
makes it idempotent. **Verdict OK.**

**Boot itself**: die partway through `reload_adopted_packs` (some packs
loaded, some not). All `load_pack` effects are in-memory and die with the
process; the only persistent write is the hash-mismatch disable+gap, which
is idempotent. Restart re-runs boot from scratch. **Verdict OK
(re-runnable).**

### 10.2 The per-pack-name invariant — supersession (DECIDED)

**The invariant:** at most one ACTIVE `mod_promotion` per pack name.
Before it was enforced, `process_adoption_tickets` created a new
`mod_promotion` unconditionally and never disabled a prior active of the
same name. The soak churns UNIQUE names per rotation, so it never hit
this in normal operation; the harness bug hit it by re-adopting the same
name after amnesia. But the design explicitly allows the agent to propose
UPDATES to its own prior packs as fresh proposals (a version update
adopts the same pack name again), and nothing disabled the prior active —
so a legitimate version update would have produced two actives too.

**Decision: adoption-time supersession** (owner-approved over the
fail-closed refusal alternative, which would have added an owner step to
every routine version update for no security gain — the new version
already cleared the full gate/trial/approval chain). Implemented as **step
6 of the canonical adoption order** (§1): after the real `promote`
succeeds and the new promotion is active, `Adopt.supersede_prior_actives`
disables every OTHER active promotion for the same pack name, recording
`superseded_by = <new promotion id>` on each. Placed after the promote so
a crash mid-adoption can never disable the old version while failing to
install the new one (which would leave the pack with zero actives). It is
a bookkeeping disable, not a `disable_pack`: `load_pack` of the new version
already replaced the old code under the same name. The invariant is now
structurally maintained by the adoption path — boot never sees two actives
from the legitimate flow.

### 10.3 Boot-time posture on ambiguity — heal, narrowly (DECIDED)

**Decision: heal, narrowly** (owner-approved over fail-closed, which would
silently drop a pack the owner may depend on until they notice the park).
Boot heals ONLY what the event log makes unambiguous, and **every heal
raises a reflection `capability_gap`** (the hash-mismatch-at-boot
precedent — nothing boot does to reconcile is silent). The **never-guesses
rule**: anything the log does not decide is parked, not resolved.
Implemented in `Boot.reconcile_promotions` / `Boot.reload_adopted_packs`:

- **A `loading` record whose `promote.applied` marker is in the log** is a
  provably-completed promote whose recorder never ran → resolve to active,
  load, close any still-open adoption ticket (so the chassis does not
  re-run and wedge), gap. This closes §10.1 case 6, the serious window.
- **Two active promotions for one pack name** → supersede the older by
  recency (consistent with §10.2's semantics), load the survivor, gap.
- **A `loading` record with NO marker** is an incomplete adoption the log
  does not decide → park it (terminal + gap), load nothing; the chassis
  re-runs its open ticket against a clean slate. This closes §10.1 case 5.
- **Otherwise recency decides**: an active shadowed by a MORE RECENT
  disable stays down. Anything genuinely ambiguous beyond the two heal
  cases above stays parked — heal never guesses.

### 10.4 Classification

- **Real product gaps, now RESOLVED:** §10.1 case 5 (orphaned `loading`
  records → parked), case 6 (live promoted state with the pack unloaded,
  the serious one → healed), case 9 (duplicate `mod_rollback` →
  idempotency guard), and §10.2 (no per-pack supersession → adoption-time
  supersession). The invariant is now maintained on both the adoption path
  and boot.
- **Accepted, documented, no code:** §10.1 case 8 (a bounded one-cycle
  transient the open disable ticket already resolves) and case 3
  (duplicate `gate_result` audit rows on a mid-adoption re-run).
- **Test-harness-only:** the durable-state / immediate-persist gap and the
  missing invariant assertion were both harness bugs. The runtime and the
  adoption machinery did exactly what they were told each time; the
  harness told them the wrong thing after amnesia.

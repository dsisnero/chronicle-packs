# LLM Author: design

**Status: KEYLESS AND HOST-BOUND. The author boundary is implemented in
`src/chronicle_packs/evolution/author.cr` (`Author`, `AuthorService`,
`AuthoredSource`) and is proven against deterministic, keyless fixtures. A
host-bound `AuthorService#draft(frame)` returns exactly four Crystal source
bodies (object types, behaviors, settings, tools) and nothing else; pack code
owns identity, manifest, entrypoint, provenance, and the chassis-owned trial
scenario. The Crystal port never points the author at a live model: direct
provider clients are out of scope and provider/credential transport stays
behind the host's Crig `ModelExecutor` seam. Gates 1 (subprocess isolation),
2 (independent design review), 3 (drafting records render on the decision
surface), 4 (enforced-boundary fixtures on the real author path), and 6
(rate/budget caps) are MET. Live-model operation remains out of scope for
this port and is a documented divergence — see
[intentional divergences](../plans/parity.md#intentional-divergences). HARD
RULE retained: the author is never pointed at a live model on a credentialed
machine from pack code.**

## History

- **The keyless boundary is BUILT.** `author.cr` implements §3 origin-based
  frame assembly (four fixed sections, every excluded origin provably absent),
  the sealed drafting record with taint recomputed from admitted ids, the
  one-shot no-tools author call, pack-owned name/provenance (`agent_` prefix,
  manifest `authored_by`, the host produces four source bodies and nothing
  else), and the §5 rate/budget caps. `spec/chronicle_packs/evolution_spec.cr`
  covers origin assembly and exclusions, wrapping under the real author, the
  taint-plus-caps behavior, and the end-to-end drafting-record render.
- **Design review retained.** The origin-over-content posture is the correct
  and only defensible architecture; the no-tools-during-drafting property is
  airtight; and building the drafting-record renderer ahead of the author was
  the right sequencing. The four required changes are enforced with specs:
  charter integrity as a gate (§3a/§8), drafting-record tamper-evidence via
  taint recompute (§4), the exception-message question closed as NO for v1
  (§3b/§8), and structured-field charset validation (§3b/§6). The exclusion of
  prior proposals' rationales (§3/§5) is kept as-is.

The evolution pack
([evolution-design](../vendor/activegraph-packs/docs/evolution-design.md))
runs gap, proposal, gates, trial, held approval, adoption. Its
`Evolution.submit_proposal_fn` is the one authoring entry point, and
everything downstream treats a scripted generator, an owner-drafted pack, and
a keyless LLM author identically. This document designs that author: the
component that reads a `capability_gap` and drafts candidate pack source with
a model.

## 1. The threat this design is against

An LLM author is where prompt injection meets code generation. The
output side is already governed: gates that parse rather than trust,
a fork trial, a bundle-hash pin, and a verified owner reading the full
diff on the decision surface. The unguarded side is the INPUT: the
drafting context. A model that reads attacker text while holding a
code-emitting pen can be steered into writing the attacker's pack, and
the pack will be syntactically clean, gate-compliant, and plausible on
review.

The existing taint machinery covers one path into that context. Gap
lineage is deterministic: `Evolution.open_reflection_gap_fn` unions
`injection_flags` from every reviewed `capability_result`, the
gatekeeper suspends tainted proposals before gating, and no model
choice can launder the flags away. What gap lineage does NOT cover:

- A poisoned memory. The memory packs store text distilled from
  conversations, and conversations quote tool output, web content, and
  channel messages from arbitrary senders. A memory can carry an
  instruction planted weeks before the gap existed, with no
  injection_flags anywhere on the gap's lineage.
- A poisoned profile. `agent_profile` goals and instructions are
  patchable state; anything that ever got write access can leave
  standing orders the author would read as owner intent.
- Poisoned failure evidence. The gap's underlying
  `capability_result.output_data` is tool-derived text by definition.
  Its flags inherit, but the tripwire is regex heuristics, and an
  unflagged result is unflagged text, never clean text.

That is the hole this design closes: the author frame must be built
so that text of those origins either never enters it, or enters
neutralized and leaves a deterministic mark on the proposal.

## 2. Posture in one line

Classify by ORIGIN, never by content. Content scanning stays what it
has always been here, a tripwire that flags and audits. Admission to
the author frame is decided by where text came from, and the default
for every origin is OUT.

## 3. The drafting context, assembled

The author frame is built by pack code (deterministic assembly), never
by the model choosing what to read. It has exactly four sections, in a
fixed order, and nothing else. `AuthorFrame.assemble` returns an
`AuthorFrame::Assembly`; `Assembly#frame` flattens it to the pure-data
`Hash(String, JSON::Any)` a host `AuthorService` may receive.

**(a) The charter.** The system prompt: what a pack is, the authored
file set, the import allow-list, the size caps, the manifest format,
the house constraints (registration signatures, settings defaults).
Repo-shipped, version-controlled, and hash-pinned: the charter's
sha256 is recorded on the drafting record (`AuthorFrame.charter_text_and_hash`
and `AuthorFrame::CHARTER_TEXT`, embedded at compile time from the pinned
vendor charter), so "which instructions was the author under" is
answerable forever. No runtime string interpolation into the charter, ever.

The charter is the ONE fully-trusted origin in the frame, so its trust
is enforced, not merely asserted. Three rules, all mechanical:

- **Human-PR-only.** The charter changes through the same PR review as
  any repo file, by a human. No runtime path writes it.
- **Never an authorable target.** The charter path is a reserved
  authored path, in the same gate family as the reserved capability
  namespaces. A proposal whose file set includes the charter path is
  refused at `static:reserved_paths`, the FIRST gate, before file-set
  or manifest checks run (implemented: `Evolution::Analysis.check_reserved_paths`,
  `EvolutionSettings.reserved_paths`, default
  `["author_charter.md"]` via `DefaultReservedPaths`).
- **Charter improvement is permanently out of scope for any autonomous
  loop**, not just v1. A system that tunes its own author's
  instructions has removed the one origin the whole posture trusts.
  This is a standing rule, not a deferral.

**(b) The gap, structured.** From the `capability_gap` and its
evidence chain, STRUCTURED FIELDS ONLY. The admitted field paths are a
closed allow-list, `AuthorFrame::ADMISSIBLE_FIELD_PATHS`:
`provider_name`, `capability_name`, `risk_class`, `exception_type`, and the
two count fields `failure_count` and `n`. (Object types are NOT a section-(b)
field — they reach the frame only through the target surface, section (c),
from the manifest.) The free-text fields (`description`,
`capability_result.output_data`, message bodies, tracebacks beyond the
exception type and frame names) do not cross. A traceback quotes the
failing input; the failing input is the attacker's text in the
tool-failure case. If the owner wants the author to see prose about
the gap, the owner writes that prose (section d).

The exception MESSAGE never crosses either, closed as NO for v1: the
message embeds attacker input by construction (a failing capability
call quotes what it was called with), and there is no honest
"sanitized" for text whose whole risk is that it is prose. Admit the
exception TYPE and frame names only. Debuggability is served by the
owner reading the actual `capability_result` on the GOVERNED decision
surface, never by piping it into the UNGOVERNED author frame. A
"lightly sanitized message" would split the difference and gut the
origin rule, so the door stays shut.

"Structured fields only" is enforced by charset, not by intent: a
capability NAME that reads like a sentence is prose wearing an
identifier's slot. At frame assembly every admitted field is validated
against the manifest charset the runtime already defines
(`AuthorFrame::MANIFEST_NAME_RE`, `^[a-z][a-z0-9_]{1,63}$`, for
provider/capability names; `AuthorFrame::EXCEPTION_TYPE_RE`, a dotted
identifier, for exception_type; `AuthorFrame::RISK_CLASSES` for risk class;
an integer for counts), and a field path outside this closed
allow-list is inadmissible entirely. A field carrying prose-shaped text
is REFUSED, not passed through as an "identifier" (implemented:
`AuthorFrame.validate_structured_fields`, enforced as a submission
backstop in `Evolution.submit_proposal_fn`). This bounds the residual
channel §6 names to actual identifiers.

**(c) The target surface, from source of truth.** Manifests of the
packs the candidate will sit beside (declared surfaces, consumed
capabilities), the object-type schemas it must write against, and the
relevant runtime contract excerpts. All repo-shipped or
loader-introspected (`AuthorFrame._loaded_surface` reads `pack.loaded`
events). Nothing here originated from a conversation. In the Crystal
port, pack identity continues to be resolved through the explicit
`Chronicle::Packs::Registry` surface rather than a Python entry-point
mechanism (see the divergences note).

**(d) Owner text, verified.** Free-text drafting guidance is admitted
from exactly one origin: `chat_input` whose sender resolved to a
verified principal holding an approver role (the identity_auth check
the adoption capabilities already require). `AuthorFrame._verified_owner_inputs`
admits exactly that, crossing the text wrapped in the tool_gateway
EXTERNAL CONTENT envelope anyway (`ToolGateway::Untrusted.wrap_untrusted`),
and it still passes `ToolGateway::Untrusted.scan_for_injection`; a hit
flags the drafting record rather than blocking, same tripwire semantics
as everywhere else.

Explicitly and permanently excluded from the frame, v1: memory pack
retrieval results, agent_profile goals and instructions, any
`capability_result.output_data`, any web or MCP tool text, any channel
message from an unverified sender, and prior proposals' rationales
(a rejected proposal's rationale is model text that may itself be the
payload). Exclusion is the mechanism that needs no correctness proof;
neutralization is reserved for the one origin (owner text) where
exclusion would gut the feature.

## 4. The drafting record

Every draft writes a `drafting_context` object BEFORE the model call:
the charter hash, the gap id, the exact object ids and field paths
admitted under (b) and (c), the owner chat_input ids admitted under
(d), and the injection flags found on any of them. `Author.draft_for_gap`
creates the record from the assembled `AuthorFrame::Assembly` and seals it
before the host author call; the model's output is a file set, and file
sets cannot patch the record.

The taint enforcement does not trust the record's stored flags field.
`Evolution.submit_proposal_fn` RECOMPUTES the injection-flag union from
the objects the record ADMITTED, read fresh from the graph by id
(`AuthorFrame.recompute_drafting_taint`), and the proposal inherits that
recomputed union, never the value the record stores. This is the §4 analog
of gap-lineage's "no model choice can launder the flags" rule, applied where
it matters most: a record that lies about its own cleanliness (or a
record-corruption bug that empties the flags field) while admitting a tainted
object still yields a suspended proposal, because the union is derived from
the admitted ids, not from any field a writer could tamper with (fixture: a
record with an empty stored flags field but a flagged admitted owner input
still suspends). A tainted context yields a suspended proposal even when the
model output looks pristine, and the decision surface
(`Evolution::Review`, `src/chronicle_packs/evolution/review.cr`) renders the
drafting record next to the diff so the owner sees what the author read,
never just what it wrote.

## 5. The author frame's mechanics

- **One shot, no tools.** The author gets the assembled context and
  returns source. It holds zero gateway capabilities during drafting:
  no search, no memory recall, no fetch. As BUILT, the frame handed to
  the model is a pure-data `Hash(String, JSON::Any)` with no graph handle
  and no capability, so "no tool surface at all" holds by construction:
  there is nothing to call. The frame is pure data by its type.
- **Output is source bodies, nothing else.** As BUILT
  (`author.cr::AuthoredSource`), the author returns exactly four source
  bodies (`object_types_src`, `behaviors_src`, `settings_src`, `tools_src`)
  and nothing else. Pack code owns `pack.cr`, `entrypoint.cr`, the manifest
  with its provenance, and the chassis-owned `trial_scenario.cr`, so the
  author STRUCTURALLY cannot set the pack name (an `agent_` prefix it never
  sees), cannot set provenance, and cannot emit the charter path.
  `Author.wrap_source` reopens the generated pack module around the four
  bodies so the `pack` macro collects their `@[Chronicle::Packs::Annotations::*]`
  declarations. This is a Crystal source-pack ABI: the candidate is compiled
  Crystal source, not a dynamically imported Python package, and the candidate
  file set includes the chassis-owned `trial_scenario.cr` (`Evolution.render_trial_driver`).
  The proposal is submitted with `authored_by="llm"` (the decision-surface
  banner reads this); the manifest's coarse runtime flag is `agent` (the
  runtime's provenance vocabulary is human/agent). Content hash is the
  runtime's (`Evolution::Materialize`).
- **The decision surface shouts.** `authored_by="llm"` renders the
  loud author banner, plus the drafting record: charter hash, admitted
  ids, flags. An owner approving an LLM-authored pack sees what it
  read and what it wrote, on one page (`spec/chronicle_packs/evolution_review_spec.cr`).
- **Budget and rate.** As BUILT: at most one draft in flight per gap
  (`Author._proposal_in_flight_for_gap?`), a daily cap on drafts
  (`EvolutionSettings.max_drafts_per_day`, counted from `drafting_context`
  objects by day), and no redrafting loops. Assembly never reads a prior
  proposal or its gate details, so a retry is a fresh draft from the same
  (a) through (d) context; there is no channel to feed a rejection back.
  `spec/chronicle_packs/evolution_spec.cr` covers all three caps.

## 6. What this does NOT claim

- It does not claim the model cannot write a malicious pack from a
  clean context. The gates, the trial, the pins, and a reading owner
  remain the containment for that, and the size caps exist so the
  reading is real.
- It does not claim the regex tripwire catches injections. Origin
  classification is the control; the tripwire is an audit trail.
- It does not claim structured fields are unpoisonable. A capability
  NAME could in principle carry a payload, so §3b charset-validates
  every admitted field against the manifest identifier pattern and
  refuses prose-shaped values: the channel is bounded to identifiers,
  which is as small as this gets. A payload that fits inside a valid
  `^[a-z][a-z0-9_]{1,63}$` identifier is the residue that remains, and
  the gates, trial, pins, and reading owner are its containment.
- It does not cover a hostile owner. A verified approver steering the
  author toward a bad pack is out of scope by definition: that person
  already holds approval power.

## 7. Gate conditions to build (all of them, no substitutions)

- **Gate 1 — MET.** Runtime subprocess isolation for fork trials, so a
  hostile candidate's first execution happens outside the parent process.
  The Crystal host seam is `Evolution::SandboxLifecycleService`
  (`src/chronicle_packs/evolution/lifecycle.cr`) joined to
  `Chronicle::Sandbox::LocalSubprocessTrialExecutor`; the parent never
  requires or evaluates candidate source.
- **Gate 2 — MET.** Design review retained, with four required changes, all
  folded and enforced with specs: charter reserved-path
  (`Evolution::Analysis.check_reserved_paths`, `spec/chronicle_packs/evolution_analysis_spec.cr`),
  drafting-taint recompute (`AuthorFrame.recompute_drafting_taint`),
  structured-field charset (`AuthorFrame.validate_structured_fields`),
  and the exception-message exclusion (asserted in the assembly specs).
- **Gate 3 — MET.** The decision surface renders drafting records (§4). The
  `drafting_context` schema is registered, `Evolution::Review.build_review`
  / `render_review_html` render it as its own section (what the author
  read, origin classes, taint union, charter hash), submission recomputes
  the record's flags deterministically, and the review specs render an
  end-to-end authored proposal (banner, read-beside-wrote, taint). A
  tainted record suspends with a loud banner and no approve path.
- **Gate 4 — MET.** Acceptance specs for the author frame itself,
  deterministic, keyless, against the real author path
  (`src/chronicle_packs/evolution/author.cr`):
  - assembly is four §3 sections and nothing else; a planted memory,
    profile goal, tool output, prior rationale, and the exception
    message all provably never reach the frame; it admits exactly the
    §3 set.
  - pack-owned name (`agent_` prefix) and provenance, the model returns
    source bodies only, no-tools by construction (the frame is pure
    data), the charter can never be authored, the charset fold excludes
    a prose field at assembly, and the authored pack passes a real
    isolated trial.
  - a tainted CONTEXT suspends even when the host OUTPUT is pristine;
    the three §5 caps (one-in-flight, daily, no-redraft).
  - the four enforced folds are proven in
    `spec/chronicle_packs/evolution_spec.cr` and
    `spec/chronicle_packs/evolution_analysis_spec.cr`.
- **Gate 6 — MET.** Rate/budget caps (§5): one draft in flight per gap, the
  daily cap (`EvolutionSettings.max_drafts_per_day`), and the no-redraft
  property.

**Gate 5 (the soak) is host-run and retained.** The portable soak rotations
(`src/chronicle_packs/evolution/soak.cr`) exercise happy and adversarial
recovery, but the Crystal author runs keyless only; pointing the author at a
live model on a credentialed machine stays a host decision and a documented
divergence (`plans/parity.md`).

## 8. Open questions

Two of the three are now closed by the review (§3b, §3a); one remains.

- **CLOSED (review): exception message.** Whether (b) admits a
  sanitized exception message is answered NO for v1 (§3b). The message
  embeds attacker input by construction and has no honest "sanitized"
  form; type and frame names cross, the message does not, and
  debuggability lives on the governed decision surface.
- **CLOSED (review): charter evolution.** The charter is human-PR-only,
  a reserved authored path enforced at the first gate (§3a), and
  charter improvement is permanently out of scope for any autonomous
  loop. The "by hand only, presumably" is now a gate, not a
  presumption.
- **OPEN: multi-turn drafting with the OWNER in the loop** (owner reads
  a draft, replies, author revises): each turn re-runs §3 assembly and
  appends to the drafting record, which the design supports in
  principle, and v1 still ships single-shot.

## Crystal divergences

- **Source-pack ABI, not dynamic import.** Candidate packs are compiled
  Crystal source with an explicit `pack.cr` entrypoint; the candidate file
  set includes the chassis-owned `trial_scenario.cr`. The Python
  `__init__.py` / `fixtures/run_fixtures.py` template and runner are
  language/host divergences.
- **Entry points.** Pack discovery goes through the explicit
  `Chronicle::Packs::Registry` rather than Python importlib entry points.
- **Pydantic → `JSON::Serializable`.** Vendor Pydantic field constraints
  collapse to Crystal type/requiredness; there is no `extra="forbid"`
  validator equivalent.
- **Provider clients.** Direct Anthropic/OpenAI clients are out of scope;
  model transport stays behind the host's Crig `ModelExecutor` seam.

See [intentional divergences](../plans/parity.md#intentional-divergences).

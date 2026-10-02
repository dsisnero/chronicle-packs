# Pack Manifest Specification

**Status: FROZEN upstream (2026-07-08), except §5. This page is the Crystal
port's adaptation of `vendor/activegraph-packs/docs/manifest-spec.md`. The
vendor spec is language-agnostic; the Crystal reference implementation is
`Chronicle::Packs` in the `chronicle` shard
(`lib/chronicle/src/chronicle/packs/manifest.cr` and
`lib/chronicle/src/chronicle/packs/value_objects.cr`). This repo owns the
spec document plus the migration and candidate tooling
(`ManifestGenerator`, `ManifestTools`, `Evolution::Analysis`). §5 (sources,
resolution, pins) stays PROVISIONAL and is not consumed by this port; see the
note at the top of §5.**

The freeze condition was met: the runtime's Q1–Q8 answers are folded in (§9),
and the evolution pack consumes this spec in its static gates (manifest
validity, both hashes, and the two-way surface check). Changes from here are
spec amendments with changelog entries, agreed with the runtime, never silent
edits.

## 1. Why a manifest

A pack is a Crystal module wired by convention: a `Chronicle::Packs::Pack`
object built by the pack DSL's `pack(...)` macro, `# requires=[...]` /
`# integrates_with=[...]` comments in `pack.cr`, and explicit registration
with `Chronicle::Packs::Registry`. That works for one repo of hand-written
packs and fails for everything now arriving:

- **Agent-authored packs** (evolution pack): a validator needs a
  machine-readable declaration to check code against, and an approval
  surface needs a stable identity (name, version, content hash) to pin
  what the owner reviewed.
- **Multi-repo loading** (third-party pack repos, a host's pack-sources
  config): an installer needs dependencies and compatibility ranges before
  it imports anything.
- **The runtime loader**: fail-loud validation at load time instead of
  import-time surprises.

The manifest is the static, declarative half of a pack. The `Pack` object
remains the runtime artifact. The loader's job is to verify the two agree
(`Chronicle::Packs.verify_surface`).

Section 5 note: with the upstream vc extraction cancelled, §5 currently has no
consuming implementation in this port either. It stays in the spec as the
designed shape, marked provisional, so a future pack-sources host starts from
reviewed rules instead of a blank page.

## 2. File format and location

One file, `manifest.toml`, at the pack root, next to `pack.cr`.

TOML because Crystal has a stdlib-independent `toml` shard that the runtime
already depends on, TOML has no code-execution surface, and the format keeps
comments. YAML would add a dependency; JSON has no comments.

A pack without a manifest keeps loading exactly as today (grandfathering is a
loader policy decision, see open question Q2). A pack WITH a manifest gets
validated against it.

The Crystal candidate path uses a reduced manifest shape (`[pack]` +
`[pack.provenance]` + `[pack.integrity]` + `[surface]`); the full generated
pack manifest additionally carries `[dependencies]` and `[fixtures]`. See
`Evolution::Author._manifest` for the candidate shape and
`ManifestGenerator.generate` for the full shape.

## 3. The schema

Illustrated with a realistic example, then field-by-field. The example is the
shape `Chronicle::Packs::ManifestGenerator` writes:

```toml
[pack]
name = "meeting_notes"
version = "0.1.0"
description = "Extracts decisions and action items from meeting transcripts."
license = "Apache-2.0"

[pack.provenance]
authors = ["Yohei Nakajima <yohei@example.com>"]
authored_by = "human"            # "human" | "agent"
generator = ""                   # agent identifier when authored_by = "agent"
source_url = "https://github.com/yoheinakajima/activegraph-packs"
created_at = "2026-07-08T00:00:00Z"

[pack.integrity]
content_hash = "sha256:9f8a..."  # see §4
# signature = ""                 # reserved, see §7

[dependencies]
activegraph = ">=1.9,<2.0"       # PEP 440 range
python = ">=3.11"
python-deps = []                 # PEP 508 distribution names

[dependencies.packs]
core = ">=0.1"
communication = ">=0.2"

[dependencies.optional-packs]    # integrates_with, checked at runtime
identity_auth = ">=0.1"
tool_gateway = ">=0.3"

[surface]
object_types = ["meeting", "decision", "action_item"]
relation_types = ["decided_in", "assigned_from"]
behaviors = ["transcript_ingester", "decision_extractor"]
tools = ["summarize_meeting"]
settings_schema = "MeetingNotesSettings"

# Gateway capability registrations this pack's HOST WIRING performs, with
# their risk classes (closed set: low | medium | high | critical). Empty
# for packs that register none. Verified statically, never by the loader;
# see the mechanism split below.
[[surface.capabilities]]
provider = "meeting"
capability = "export_summary"
risk_class = "medium"
credential_ref = ""              # name only, never a value
action_class = "R1"              # optional canonical consequence class (ADR 0016)

# Capabilities this pack's behaviors INVOKE at runtime (creates
# capability_call objects). Decision surfaces and reviewers read this to
# see a pack's outbound reach before approving it.
consumes = ["web.fetch_url"]

[fixtures]
entrypoint = "fixtures/run_fixtures.py"
deterministic = true             # asserts: no network, no API keys
```

> **Crystal candidates.** An agent-authored Crystal candidate is written by
> `Evolution::Author.wrap_source`, which emits `manifest.toml` + `pack.cr` +
> `entrypoint.cr` + `trial_scenario.cr` (with the four authored bodies already
> wrapped in the generated pack module). Its manifest contains only `[pack]`,
> `[pack.provenance]`, `[pack.integrity]`, and `[surface]` (with
> `capabilities = []`); it omits `[dependencies]` and `[fixtures]`. The
> candidate file set is closed by `Evolution::DefaultCrystalAllowedFiles`
> (`manifest.toml`, `pack.cr`, `entrypoint.cr`, `object_types.cr`,
> `relation_types.cr`, `behaviors.cr`, `tools.cr`, `settings.cr`,
> `capabilities.cr`, `trial_scenario.cr`); anything else is rejected by
> `Analysis.check_crystal_file_set`. The trial pins exactly one candidate pack
> — the upstream trial's `extra_packs` parameter is not ported
> (`vendor/activegraph-packs/docs/evolution-design.md` §; see
> [parity](../plans/parity.md)).

### `[pack]` (required)

| Field | Rule |
|---|---|
| `name` | `^[a-z][a-z0-9_]{1,63}$` (`Chronicle::Packs::MANIFEST_NAME_RE`); unique within a load set; matches the directory name and `pack(name: ...)` |
| `version` | PEP 440 core grammar (`Chronicle::Packs::VERSION_RE`); must match `Pack#version` |
| `description` | nonempty; shown in catalogs and decision surfaces |
| `license` | SPDX identifier when nonempty; empty string allowed. Validators check SPDX validity only; the policy that published packs must carry a license lives in publisher tooling, where "published" is actually knowable |

### `[pack.provenance]` (required)

Provenance records where a pack came from. It never confers trust.
Trust is assigned by the installer (bundled, installed, agent-authored
are trust *tiers the host tracks*, never manifest claims), because a
manifest saying "trust me" is worth exactly nothing. `authored_by =
"agent"` is a disclosure flag consumers like the evolution pack's
decision surface render loudly; a missing or false flag is caught by
the host that generated the pack, not by the manifest itself.

### `[pack.integrity]` (required)

`content_hash` pins the bytes. See §4. `signature` is a reserved key so
the schema does not break when signing lands; validators MUST reject
ANY non-empty signature value today, because no algorithm is
implemented and "recognized prefix but unverifiable" must not become a
pass-through (Q6, sharpened by the runtime review).
`Chronicle::Packs.load_manifest` and
`Evolution::Analysis.check_crystal_manifest_signature` both enforce this.

### `[dependencies]` (required, sub-tables optional)

- `activegraph`: PEP 440 range. In this port the "runtime" is the compiled
  `chronicle` shard, so the generated floor is `>=1.9,<2.0` (the canonical
  `action_class` contract, CONTRACT v1.9). `Chronicle::Packs.load_manifest`
  validates the specifier-set grammar; it does not resolve a live runtime
  version. The Crystal candidate path omits `[dependencies]` entirely.
- `packs` (hard deps) and `optional-packs` (the existing
  `integrates_with` convention, checked lazily at runtime with graceful
  degradation, matching current pack behavior).
- `python-deps`: PEP 508. The upstream loader verifies DISTRIBUTION PRESENCE
  via `importlib.metadata.version(dist_name)` and reports what is missing;
  it does not install, and it does not test importability. **Not ported:**
  Crystal has no distribution-metadata registry, so the port validates the
  list shape and stores it but performs no presence check. This is an
  intentional language boundary recorded in
  [parity](../plans/parity.md#intentional-divergences).

> **TOML ordering.** A bare key must appear BEFORE the sub-tables below; in
> TOML, a bare key after a table header would belong to that sub-table.
> `ManifestGenerator` emits `[dependencies]` keys first, then
> `[dependencies.packs]` / `[dependencies.optional-packs]`.

### `[surface]` (required)

The declared capability surface. The two-way check ("everything
registered must be declared, everything declared must exist") is what
makes the manifest useful to the evolution pack's static gates and to
any reviewer: the declaration is the contract, the code cannot quietly
exceed it. Strictness level is Q3. It is enforced by TWO mechanisms,
because the surface has two kinds of members:

**Loader-verified at load time** (`Chronicle::Packs.verify_surface`,
introspection of the `Pack` object): `object_types`, `relation_types`,
`behaviors`, `tools`, `settings_schema`. The identity mapping, so
implementations agree:

| Manifest list | Matches |
|---|---|
| `object_types` | each `ObjectType#name` in `Pack#object_types` |
| `relation_types` | each `RelationType#name` in `Pack#relation_types` |
| `behaviors` | each `PackBehavior#name` in `Pack#behaviors` |
| `tools` | each `Tool#name` in `Pack#tools` |
| `settings_schema` | `Pack#settings_schema` (the class name string via `SettingsSchema.pack_settings_name`; empty string when the pack has no settings) |

**Statically verified, and (for capabilities, since v1.4) also
loader-verified**: `[[surface.capabilities]]` and `consumes`. Gateway
capability registration is imperative host wiring
(`ToolGateway.register_local_capability` calls at startup, sometimes
conditional on optional packs), which the loader cannot observe. The static
half is a parser-validated source walk performed by CI in this repo and by the
evolution pack's static gates:

- **Full/generated packs** read the live `Pack` object
  (`ManifestTools.extract_capability_registrations` returns
  `CapabilityDecl`-shaped rows; `ManifestGenerator` writes them into the
  manifest). The DSL already collected the declared surface at compile time.
- **Crystal candidates** are scanned by
  `Evolution::Analysis.extract_crystal_declared_surface` with the Crystal
  compiler parser: every `@[Chronicle::Packs::Annotations::ObjectType(...)]`,
  `@[Annotations::RelationType(...)]`, `@[Annotations::Behavior(...)]`,
  `@[Annotations::Tool(...)]`, and `CapabilityDecl.new(...)` declaration must
  match the manifest and vice versa.

Q8 is now resolved (see §9): the runtime ships a declarative
`Pack.capabilities` field, so `verify_surface` ALSO does a
loader-side two-way check of capabilities (presence, `risk_class`,
and `action_class`) against the live pack — the same check it does for
behaviors, tools, and object types. Capabilities are therefore checked on
both sides (loader + parser-validated source, defense in depth). In this
port `consumes` is derived from the pack's declared capability keys rather
than from an AST invocation scan; the upstream one-way "every declared
consumed capability is actually invoked" check is an intentional divergence
(no Crystal AST call-site walk), recorded in
[parity](../plans/parity.md).

`risk_class` is a closed set: `low | medium | high | critical`
(`Chronicle::Packs::RISK_CLASSES`), matching tool_gateway's
`CapabilitySpec`. Validators reject anything else.

`action_class` (ADR 0016, runtime CONTRACT v1.9) is
the OPTIONAL canonical consequence class: closed set
`R0 | R1 | R2 | R3 | R4` (`Chronicle::Packs::ACTION_CLASSES`); absent means
undeclared. It is a SEPARATE policy dimension from `risk_class` —
validators, the loader, the generator, and every consumer treat the two
independently, and no tool may infer one from the other (there is no
`low→R0`-style mapping, anywhere). A capability without an `action_class` is
ineligible for the runtime's action-class auto-approval path (it fails closed
to approval). `verify_surface` requires manifest/Pack agreement on
`action_class` exactly like `risk_class`, including presence — a class
declared on one side and absent on the other is a caught relabel. The
generator writes the key only when declared, so packs without action
classes keep their exact prior manifest shape.

`[[surface.capabilities]]` and `consumes` entries matter to governance
tooling: the capability catalog and decision surfaces read
risk classes, action classes, and outbound reach from here without
importing the pack.

### `[fixtures]` (required for full packets)

Every upstream pack ships runnable, deterministic fixtures; the manifest
makes it checkable. `deterministic = true` is an assertion the CI harness
enforces (no sockets, no key reads), not a wish.

Fixtures are test harness, never loaded runtime code, and are governed
by the `deterministic` assertion rather than by any import allow-list a
consumer applies to runtime source.

> **Crystal port.** The standalone `fixtures/run_fixtures.py` entrypoint has
> no runtime equivalent; deterministic scenarios run in-process through
> `Chronicle::Packs::FixtureRunner` (driven by specs and
> `Chronicle::Packs::Fixtures`). `ManifestGenerator` still writes the
> upstream `entrypoint = "fixtures/run_fixtures.py"` string for manifest
> compatibility. The evolution candidate path omits `[fixtures]` entirely.
> See [parity](../plans/parity.md).

## 4. Content hash

`content_hash` = `"sha256:" + hex(sha256(canonical_bytes))` where
`canonical_bytes` is computed over the pack directory:

1. Collect every regular file under the pack root, recursively,
   EXCLUDING: `manifest.toml` itself (a hash cannot cover itself),
   `__pycache__/`, `*.pyc`, hidden files (`.` prefix), and symlinks
   (rejected outright, see Q5).
2. Sort the relative POSIX paths lexicographically (bytes).
3. For each file, append: the UTF-8 path, a NUL byte, the 8-byte
   big-endian file length, the raw file bytes.

Properties: platform-independent given identical bytes (no newline
normalization: the bytes are the contract; publish from one platform),
order-independent of filesystem enumeration, resistant to
file-boundary confusion (length prefix).

Edge rules, each normative (folded from the runtime's Q5 review):
directory symlinks are rejected exactly like file symlinks (a symlinked
subdir would smuggle unhashed content through a naive walk); paths that
do not encode as UTF-8 are rejected loudly; paths must be NFC-normalized
(macOS normalizes filenames and Linux does not, so an NFD `café.cr`
would hash differently per platform); non-regular files (sockets, fifos)
are silently skipped like directories; empty directories are invisible
to the hash.

**Two hashes, two jobs.** The `content_hash` above excludes
`manifest.toml` because a hash cannot cover itself; it proves the
manifest matches the source files it ships with. That self-exclusion
makes it USELESS as an external pin: an attacker who swaps only the
manifest (risk classes relabeled, `consumes` emptied, `authored_by`
flipped, the exact document a reviewer reads) leaves `content_hash`
valid. External pins therefore use the **bundle hash**: the same walk
WITHOUT the manifest exclusion, covering every byte including
`manifest.toml`.

Reference implementations in the Crystal runtime:
`Chronicle::Packs.compute_content_hash`, `compute_bundle_hash`, and
`verify_bundle_hash` (`compute_content_hash` also has
`verify_content_hash(manifest, pack_root)`). Consumers import these, never
reimplement.

Consumers: the runtime loader verifies `content_hash` at load (policy
per Q2); the evolution pack verifies the BUNDLE hash at gate time, at
adoption time, and at every boot re-materialization
(`Evolution::Materialize`); multi-repo installers verify the bundle hash
after fetch. The exclusion list above is normative for every consumer: any
consumer phrase like "hash over the pack's file set" means the file set as
defined here.

## 5. Multi-repo loading (the shape, not the tool)

This spec defines what a pack source declaration points AT; the
resolver that fetches is host tooling. Sketch of the host-side source list
the spec is designed to support:

```toml
[[sources]]
name = "activegraph-packs"       # the general library
kind = "path"                    # "path" | "git"
location = "../activegraph-packs"
subdir = "packs"                 # pack root = <source>/<subdir>/<pack name>

[[sources]]
name = "activegraph-packs-research"
kind = "git"
location = "https://github.com/example/activegraph-packs-research"
ref = "9f2c41d..."               # commit SHA required unless pinned below
subdir = "packs"                 # default "packs"; "." for repo-root packs

[load]
packs = ["core", "tool_gateway", "chat", "research"]

[load.pins]                      # optional per-pack expected BUNDLE hashes (§4)
research = "sha256:ab12..."
```

Resolution rules, in order, all before anything imports:

1. **Pack root** is `<fetched source>/<subdir>/<pack name>` for every
   source kind, so §4's hash walk has a well-defined starting point.
2. **Precedence dominates**: a pack name resolves to the FIRST source
   that declares it. If that pick violates any pack's
   `[dependencies.packs]` range, the whole load fails loudly, and the
   error must name any satisfying versions found in lower-precedence
   sources so a human can reorder or repin.
3. **Dependency ranges** from every loaded pack's manifest must be
   simultaneously satisfiable, checked across the full load set. No
   partial loads.
4. **Hash verification, honestly scoped**: the post-fetch check against
   the manifest's own `content_hash` proves internal consistency
   (integrity in transit), never authenticity, because the manifest
   arrives with the pack and excludes itself from its own hash.
   Authenticity requires an EXTERNAL pin covering every byte INCLUDING
   the manifest: a `[load.pins]` entry, which is a **bundle hash**
   (§4), or a git `ref` that is a commit SHA.

> **Crystal port (PROVISIONAL, not consumed).** This port has no
> pack-sources host and does not read `[[sources]]`, `[load]`, or
> `[load.pins]`. Packs are loaded by explicit registration:
> `Chronicle::Packs::Registry.register(PACK)` (via the DSL's
> `pack(register: true)`), enumerated by `Chronicle::Packs::Registry.discover`
> / `Chronicle::Packs.load_by_name`. `ManifestGenerator::PACK_PATHS` is the
> explicit registered-name → directory map, and `Registry` is the Crystal
> replacement for Python entry-point discovery recorded in
> [parity](../plans/parity.md#intentional-divergences). The external bundle
> pin (`verify_bundle_hash`) and the evolution proposal pins are ported.

## 6. Consumer pressure-test

| Consumer | What it needs | Where the spec answers |
|---|---|---|
| Runtime loader | machine-checkable schema, two-way surface check, structured errors | §3, Q1, Q3 |
| This repo's CI | validate existing manifests, enforce fixtures promise | §3 fixtures, Q2 migration |
| Evolution pack | stable identity + hash pin, declared-vs-actual for static gates, risk classes visible pre-import, `authored_by` disclosure | §3 surface/integrity/provenance, §4 |
| future multi-repo host (§5, provisional) | dependency ranges resolvable cross-repo, source declarations | §3 dependencies, §5 |
| Decision surfaces | catalog metadata without import | §5, §3 provenance note, capabilities table |

The hardest consumer is the evolution pack, and it drove three
decisions: the hash canonicalization is exact enough to recompute
byte-identically in every implementation, the surface check is two-way, and
provenance is disclosure rather than trust.

## 7. Deliberately out of scope (seams left, nothing built)

- **Signing**: `signature` key reserved; algorithm choice, key
  distribution, and revocation are a separate design. The rule that
  future validators reject unknown algorithm prefixes is in the spec
  NOW so old validators cannot be downgrade-attacked later.
- **A registry/index protocol**: §5 sources are paths and git refs;
  a pack index is future host tooling.
- **Sandboxing claims**: the manifest declares, the loader verifies
  declarations; neither contains code execution.

## 8. Migration for the existing library

The upstream library gets manifests generated by a script (name,
version, description from `Pack(...)`; surface by import inspection;
hash computed; provenance filled human). CI then validates every pack's
manifest on every push, which keeps declared-vs-actual honest from day
one.

In this port the generator is `Chronicle::Packs::ManifestGenerator`
(`src/chronicle_packs/generate_manifests.cr`) and the static extraction seam
is `Chronicle::Packs::ManifestTools` (`src/chronicle_packs/manifest_tools.cr`)
plus the live `Pack` object. The port verifies byte-exact §4 hash parity
against the real upstream manifests
(`spec/chronicle_packs/vendor_manifests_spec.cr`) and never regenerates
upstream manifests, so the Python-specific `[dependencies]` / `[fixtures]`
fields stay as-is. `[[surface.capabilities]]` is generated from
`Pack#capabilities`; `consumes` is generated from the same declared keys.
Docstring conventions (`# requires=`, `# integrates_with=`) stay as
prose but stop being the source of truth.

## 9. Q1-Q8: answered (runtime review, folded 2026-07-08)

The reference implementation is `Chronicle::Packs`
(`lib/chronicle/src/chronicle/packs/manifest.cr`), the Crystal translation of
the upstream `activegraph.packs.manifest`. This repo's CI and the evolution
pack's gates import it; nothing here reimplements validation or hashing.

- **Q1 (errors): ANSWERED.** A single `PackManifestError` carrying every
  violation at once, computed before anything else, matching load
  atomicity. `load_manifest` raises it with the full violation list.
- **Q2 (grandfathering): ANSWERED, locked in CONTRACT v1.4 #1.** Validation
  is opt-in via `Chronicle::Packs.load_manifest`; the runtime does not
  enforce a manifest at `load_pack`. This repo's generator writes manifests
  and the evolution gates require one for candidates.
- **Q3 (strictness): ANSWERED.** Hard error when a manifest exists. A
  pack that opts in, opts all the way in; grandfathering is the soft
  path.
- **Q4 (python-deps): ANSWERED upstream, amended here.** Upstream checks
  distribution presence via `importlib.metadata`, never importability, and
  never installs. The Crystal port validates the PEP 508 list shape and
  stores it but performs no distribution-presence check; agent-authored
  candidates omit dependencies entirely. See
  [parity](../plans/parity.md#intentional-divergences).
- **Q5 (hash edges): ANSWERED, folded into §4.** Directory symlinks
  rejected, non-UTF-8 paths rejected, NFC required, non-regular files
  silently skipped, empty directories invisible. Ported byte-exact in
  `hash_pack_dir` and covered by `spec/chronicle/packs_manifest_spec.cr`.
- **Q6 (signatures): ANSWERED, sharpened.** ANY non-empty signature
  value is rejected today, not just unknown prefixes; no implemented
  algorithm means no pass-through. Enforced in `load_manifest` and
  `Evolution::Analysis`.
- **Q7 (ownership): ANSWERED.** The `chronicle` runtime shard owns schema
  and validation (`Chronicle::Packs`); this repo owns the spec document and
  the migration/candidate tooling (`ManifestGenerator`, `ManifestTools`,
  `Evolution::Analysis`).
- **Q8 (capability visibility): ANSWERED; the mechanism chain, recorded.**
  (1) `Pack#capabilities : Array(CapabilityDecl)` is declared through the
  DSL's `pack(capabilities: [...])`, giving the loader the same two-way
  check for capabilities as for behaviors/tools; (2) the generated manifest
  records `[[surface.capabilities]]` for graph-readable review; (3)
  gateway-side enforcement at registration is
  `ToolGateway.check_registration` (armed via
  `arm_registration_enforcement`), which refuses undeclared pairs, risk-class
  drift, action-class drift, and disabled-pack claims. The parser-validated
  source check stays as CI defense-in-depth.

# Soak runbook (LLM-author gate 5)

The soak is the one gate only time retires: the full evolution loop,
unattended, for days, on a keyless machine, with every unhappy path
exercised on rotation. This document is how you run it, what healthy
looks like, and when to stop and report.

The harness lives at `src/chronicle_packs/evolution/soak.cr`
(`Chronicle::Packs::Evolution::Soak`). Design of record for what it
exercises: [evolution-design.md](evolution-design.md); the gate it serves:
upstream `llm-author-design.md` §7.

## What one rotation does

Each rotation boots a FRESH runtime against the persistent soak store
(so boot housekeeping, principal re-indexing, and adopted-pack reload
run every time), then walks seven paths with the scripted author
(`HappyRotation#run_full_rotation`, driven by `Soak::SCENARIO_PATHS`):

| path | exercises | expected terminal state |
|---|---|---|
| tainted | deterministic taint inheritance | proposal `suspended`, zero gates run, sweeps leave it alone |
| happy | the full loop: gap, gates, subprocess trial, held critical call, scripted approval by the registered owner principal, adopt, watch window | pack live on the parent, behavior fires, previous rotation's pack governed away (`disabled`) |
| conflict_park | the retry cap | `needs_owner` after exactly `max_conflict_retries` requeues; further sweeps do nothing |
| budget_events | the runtime's event-budget net | rejected, child outcome `limits_exceeded` at replay |
| budget_wallclock | the parent-side wall-clock kill | rejected, child outcome `limits_exceeded` at the fixture gate |
| budget_memory | runaway-memory containment (platform-conditional, see below) | rejected; contained by whichever memory-related net is real on this box |
| disable_restart | governed disable plus restart persistence | `disabled (stays down)` in the reload report after a real restart |

Every path asserts its terminal state. A miss is recorded as an
ANOMALY with a traceback and the rotation continues; anomalies are
never swallowed. `HappyRotation#run_full_rotation` keeps going after a
path fails so the durable digest records every result from the same
fresh runtime, and it captures the losing trial child's own failure
detail (`latest_child_failure_detail`) alongside the soak-side
traceback.

After the seven paths, the harness also asserts its own **post-rotation
invariant** (`HappyRotation#enforce_invariants`): at most ONE `active`
promotion total (the happy path churns exactly one at a time). This runs
even when every path passed — the class of bug it guards against once let
a rotation score all seven GREEN while two adopted packs were
simultaneously live. A violation is a first-class anomaly of its own: it
names the offending promotions, flips the digest RED, and lands in the
anomaly log, exactly like a path failure. The external observer's "at
most one active" check below is now belt-and-braces — redundant by design
rather than load-bearing.

**budget_memory is platform-conditional, on purpose.** The invariant it
protects is "a runaway-memory candidate is CONTAINED", which is true on
every platform; the specific net that contains it is not. The soak keys
off the host's own memory-net signal (`HappyHost#memory_net_available?`,
which must report what the runtime/sandbox can actually enforce), never a
platform name:

- **Memory net live:** the candidate makes a fixed over-cap allocation
  and the memory net catches it; the contained child outcome is a
  resource-limit rejection.
- **Memory net unavailable:** the runtime surfaces the unenforced
  `trial_max_rss_bytes` as a host-capability warning
  (`LocalSubprocessTrialExecutor#preflight`) and the candidate then
  allocates UNBOUNDEDLY; the wall-clock kill contains it instead. A
  memory-net-unavailable warning is EXPECTED, not a red flag.

The real red flag for this path is a runaway that escapes ALL nets: a
budget_memory candidate whose trial `completed` (verdict pass). That
means nothing contained it, and it is a stop-and-report.

Keyless by construction: the scripted author writes the candidates,
trial children get no LLM provider (the trial child's model raises
`"trial has no model provider"`; `max_llm_calls` is `0` and omitted from
the child budget, so key-freedom is structural), and nothing reads an API
key. If the machine has keys anyway, the soak neither needs nor touches
them, and the harness is where that claim is tested daily.

## Environment constraint (read this before you start)

The soak runs the full loop, and the loop runs candidate code in the
runtime's subprocess trial child. That child spawns with a deliberately
closed environment allow-list (a security control: no ambient parent
env, no secrets, leaks into a process running candidate code). The local
executor builds the child's environment from `PATH`, `HOME`, and `LANG`
plus any explicit `env_passthrough`, and sets `CRYSTAL_PATH` to the
candidate root plus the repo `src` and the Crystal load path, so the
child can compile `entrypoint.cr` and `require "chronicle"` while the
allow-list stays closed.

You do not have to check the box by hand: the soak runs a **preflight**
before the first rotation; `ScheduledRunner#run_once` calls
`@rotation.preflight` and refuses to run (raises `PackError`) when the
host returns `PreflightResult(ready: false, message: ...)` — on an
incapable box the message carries the child's real error instead of
producing a digest full of identical silent crashes. The host's preflight
delegates to the runtime's sandbox capability (for example
`LocalSubprocessTrialExecutor#preflight`, which verifies `crystal
--version` and reports unenforceable `max_rss_bytes` as a warning). On a
capable box it reports `trial child OK`. If you see a refusal, the box
cannot host the soak; the message names the cause.

## Starting it

The Crystal soak is host-bound: it cannot construct a model or runtime
globally, so a host supplies a `Soak::HappyHost(M)` (fresh runtime boot,
author service, sandboxed lifecycle service, verified-owner
approve/disable callbacks, the post-adoption behavioral watch, and the
contested-parent hook for the conflict path). Then run it:

```crystal
require "chronicle-packs"

host = MySoakHost.new                      # <: Chronicle::Packs::Evolution::Soak::HappyHost(MyModel)
settings = Chronicle::Packs::Evolution::EvolutionSettings.new(enabled: true)
rotation = Chronicle::Packs::Evolution::Soak::HappyRotation(MyModel).new(
  Path.new("data/soak"), host, settings,
)
runner = Chronicle::Packs::Evolution::Soak::ScheduledRunner(MyModel).new(rotation)

runner.run(interval_seconds: 600.0)        # forever: one full rotation every 10 minutes
runner.run(rotations: 12, interval_seconds: 600.0)   # stop after 12
runner.run_once                            # one rotation, then exit
```

The rotation keeps all its state under `--root` (`data/soak`); killing
and restarting it is safe — including a kill in the MIDDLE of a rotation.
The happy path persists its adoption to `state.json` the moment it
commits (not only at end-of-rotation), so a mid-rotation kill that loses
the rotation's progress can no longer make the re-run disable a stale
target and orphan an active promotion. A killed rotation simply re-runs
from its start on restart.

One rotation takes about half a minute on a small machine (the
wall-clock scenario deliberately burns its configured timeout). At the
default 10-minute interval you get roughly 140 rotations per day, which
is far past the per-path target; the interval exists to make the store's
growth and the machine's load boring, and there is no need to shrink it.

## Reading it

Zero-setup artifact: `data/soak/digests/soak-YYYY-MM-DD.md`, rewritten
after every rotation by `HappyRotation#write_digest`. Healthy looks like:

- `status: **GREEN**`
- every row of the path table with `anomalies` at 0
- `promotions by status` showing exactly ONE `active` (the current
  rotation's happy pack; everything older reads `disabled`)
- `trials` failing only where the budget paths mean them to (the budget
  candidates)
- the boot line showing housekeeping examining fork runs and the reload
  report listing old packs as `disabled (stays down)`

`data/soak/state.json` carries the cumulative counts and the anomaly
log (`Soak::State`, `#save`/`.load`); the console prints one line per
rotation. The digest file is overwritten after every rotation (and named
per day), so a transient RED can be overwritten GREEN on the next
rotation — but every anomaly, invariant violations included, is APPENDED
to `state.json`'s `anomaly_log` and stays there regardless. If you ever
see a RED digest, read `anomaly_log`: it is the durable record, and it
does not get overwritten.

## Red flags (stop and report)

Any of these means stop the harness and bring me the digest plus the
anomaly log; do not restart over them:

- `status: **RED**`, or any nonzero `anomalies` cell. The digest's
  anomaly section carries both halves: the trial child's own failure
  detail (the real error, when a child failed) and the soak-side
  traceback (which invariant broke). A crash is never opaque here; if an
  anomaly names a child failure, that detail is the report, not the soak
  assertion above it.
- More than one `active` promotion, or an `active` count that grows
  across rotations. The governed-disable path is failing quietly. The
  harness asserts this itself post-rotation (it surfaces as an
  `invariant` anomaly naming both promotions), so a RED digest gets you
  here without your having to eyeball the count; this bullet stays as
  the belt-and-braces external check.
- A `suspended` count that ever DECREASES, or a parked `needs_owner`
  proposal that changes status. Nothing automatic may touch either.
- A budget path whose candidate `completed` (trial verdict pass): a
  runaway escaped every net. For `budget_memory` specifically, note the
  outcome is platform-conditional, so the red flag is `completed`, not
  which containment net fired.
- The happy path's behavior watch reporting zero fires with no anomaly
  recorded: the adopted behavior stopped firing without failing. In the
  Crystal runner this is `HappyHost#watch_happy`, which must raise if the
  newly adopted behavior does not fire or if it produces an attributable
  failure.
- A rotation that stops producing digests at all (crash loop, disk
  full, store corruption). The console traceback is the report.
- Any loader manifest WARNING in the console. CI validates every push,
  so a warning here means CI missed something; that is a repo bug, and
  the warning text is the report.

## Stop conditions (when the gate is satisfied)

Both must hold, and the digest computes them for you (`soak target:`
flips to MET) via `HappyRotation#target_met?` /
`Soak::State#completion_met?`:

1. At least **3 days** elapsed since `started_at` in state.json
   (`Soak::DEFAULT_MIN_DAYS`).
2. Every path's `ok` count at least **20** (`Soak::DEFAULT_MIN_PER_PATH`).

Raising `DEFAULT_MIN_DAYS` / `DEFAULT_MIN_PER_PATH` raises the bar, and
the digest states whichever target it was computed against. When the
target reads MET with a GREEN digest and an empty anomaly log, gate 5 is
satisfied: bring me the final digest and the state file, and keep the
store (the whole soak is replayable evidence, which is the point of
running it on an event-sourced substrate).

## Determinism notes

Candidate content is a pure function of the rotation index; timestamps
and scheduling touch the clock; the store accumulates honestly (a
multi-day soak is supposed to grow) while boot housekeeping
(`Boot.retire_unpinned_trial_forks`) retires disposable trial forks each
rotation, so growth stays linear in rotations. The Crystal port covers
one full rotation in CI on every push via
`spec/chronicle_packs/evolution_spec.cr` (the analog of the upstream
fixture 19), so the harness itself cannot rot while the soak machine runs
an older checkout.

## Not ported (see plans/parity.md)

The upstream `python -m packs.evolution.soak` CLI and the Python
fixture/runner modules (`fixtures/run_fixtures.py`) are intentional
divergences: the Crystal soak is a host-bound library entry point
(`ScheduledRunner`) driven by Crystal specs rather than a standalone
Python process. The upstream test/source ledger and the exact boundary
are recorded in [plans/parity.md](../plans/parity.md).

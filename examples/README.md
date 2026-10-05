# Examples

Runnable Crystal ports of the upstream
[`activegraph-packs` `bundles/examples/`](https://github.com/yoheinakajima/activegraph-packs/tree/main/bundles/examples).
Each builds a bundle, drives it with deterministic input (no API key needed),
and prints the durable graph objects and event log.

Run from the repository root:

```bash
crystal run examples/assistant_chat.cr
crystal run examples/email_assistant.cr
crystal run examples/research_assistant.cr
crystal run examples/inspect_log.cr
```

| Example | Bundle | What it shows |
| --- | --- | --- |
| [assistant_chat.cr](assistant_chat.cr) | `build_assistant` | Chat input → `comm_message` + `chat_session` + `chat_turn`; owner resolved to a `principal`. |
| [email_assistant.cr](email_assistant.cr) | `build_email_assistant` | Inbound email → `source` + `email_thread` + `comm_intent`; `entity` extraction; external `principal`. |
| [research_assistant.cr](research_assistant.cr) | `build_research_assistant` | Two papers → `paper`/`author`/`venue` + `observation` + `idea_atom` + `research_direction`; experiment creation. |
| [inspect_log.cr](inspect_log.cr) | `build_assistant` | The event log three ways (trace lines, raw stream, causal chain) and a CLI-ready log file. |

## Seeing the log

The append-only log is the source of truth. In process, read it with:

- `runtime.trace.lines` — human-readable CONTRACT trace (`TraceFacade`)
- `store.iter_events` — raw `Chronicle::Event` stream (`sequence`, `type`, `actor`, `caused_by`, `payload`)
- `Chronicle::Trace.causal_chain(events, graph, object_id)` — one object back to its cause

`examples/inspect_log.cr` prints all three and writes a `chronicle.event-log`
(JSONL) file. Chronicle also ships a CLI:

```bash
# Build the CLI once (chronicle target: src/chronicle/cli_main.cr)
crystal build -o chronicle-cli lib/chronicle/src/chronicle/cli_main.cr

chronicle-cli log inspect --file run.jsonl          # every event + payload
chronicle-cli trace --file run.jsonl --object claim#1
chronicle-cli replay --file run.jsonl
chronicle-cli fork --from run.jsonl --at 20 --out fork.jsonl
chronicle-cli diff --before a.jsonl --after b.jsonl
chronicle-cli quickstart                            # offline demo, no key
```

`--file` is a `chronicle.event-log` file: a header line plus canonical event
lines (`Chronicle::EventLogCodec`). The event store is the sequencing
authority — both `MemoryEventStore` and `Chronicle::SQLiteEventStore` stamp
each stored event with a strictly-increasing position, so the log is
codec-valid as-is (no renumbering).

## Notes on settings

Settings are typed `JSON::Serializable` structs. Where a struct has an explicit
initializer (`ChatSettings`, `EmailSettings`, `ResearchSettings`,
`MemoryGatewaySettings`) use it; otherwise construct with `from_json`
(`IdentitySettings`, `EntitySettings`).

Two upstream examples reference settings names that the vendor's own
`settings.py` no longer defines; this port uses the current names:

- `email_assistant_example.py`: `auto_extract_entities` / `dedup_similarity_threshold`
  → `extract_from_raw_sources` / `resolution_similarity_threshold`.
- `research_example.py`: `min_atoms_for_synthesis` → `min_ideas_for_direction`.

The `research` `create_experiment_fn` example tolerates a missing direction
relation and still records the `experiment` object.

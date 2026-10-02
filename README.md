# chronicle-packs

`chronicle-packs` is the Crystal port of the pinned
[`activegraph-packs`](https://github.com/yoheinakajima/activegraph-packs)
library. It provides composable Chronicle packs for an auditable, reactive
object graph: typed objects and relations are durable facts; behaviors react to
their events; tools expose governed capabilities.

The vendor source is a git submodule at
[`vendor/activegraph-packs`](vendor/activegraph-packs), pinned to
`6639a5385518ad49f74813373c85cf96eff9adc0`. Its observable behavior, tests,
and fixtures are the parity contract. Python packaging, Pydantic models, and
the vendor's UI/API process topology are not Crystal APIs.

## Install

```yaml
dependencies:
  chronicle-packs:
    github: dsisnero/chronicle-packs
```

```bash
shards install
```

## Start with a bundle

Bundles are named pack collections, not new graph ontologies. The assistant
bundle builds an in-memory runtime with a deterministic completion model, so a
key is never required for the documented baseline. A bare `build_assistant`
call seeds the owner principal and one default agent profile:

```crystal
require "chronicle-packs"

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant
puts graph.objects(type: "agent_profile").size # => 1
```

To watch the reactive graph do something, submit input and inspect the durable
objects and event log the packs produce. This is the Crystal equivalent of
upstream `bundles/examples/assistant_example.py`; the complete program is
[`examples/assistant_chat.cr`](examples/assistant_chat.cr):

```crystal
require "chronicle-packs"

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant(
  identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
    %({"owner_identifiers":["alice@example.com"]}),
  ),
)

Chronicle::Packs::Chat.submit_chat_input_fn(
  graph,
  user_ref: "alice@example.com",
  content: "Can you help me research the new transformer paper?",
  session_id: "session-demo-1",
)
runtime.run_until_idle

graph.objects(type: "chat_turn").size # => 1 (user + assistant messages)
graph.objects(type: "principal").size # => 1 (the owner)
store.iter_events.size                # full causally-linked event log
```

Run it from the repository root with `crystal run examples/assistant_chat.cr`.
Settings are typed `JSON::Serializable` structs; build them with `from_json`
(or the pack's own initializer where one exists), not by hand-assembling
`JSON::Any`.

The same layout covers the other bundles:
[`examples/email_assistant.cr`](examples/email_assistant.cr) and
[`examples/research_assistant.cr`](examples/research_assistant.cr). See
[Examples](examples/README.md).

Use `build_messaging_assistant`, `build_email_assistant`, or
`build_research_assistant` for the corresponding preset. For a durable
application runtime, construct a `Chronicle::Runtime` over your chosen event
store, then use `Bundles.load_assistant_packs` or load pack declarations in the
required order. See [Bundles](docs/bundles.md).

## Documentation

- [Documentation home](docs/README.md) — the full docs index.
- [Concepts](docs/concepts.md) — event-sourced graph coordination, pack
  boundaries, deterministic floor, and governance.
- [Architecture](docs/architecture.md) — Crystal module layout and runtime
  boundaries.
- [Pack catalog](docs/packs.md) — every ported pack grouped by role.
- [Bundles](docs/bundles.md) — included packs, configuration seams, and the
  bundle walkthrough.
- [Examples](examples/README.md) — runnable assistant, email, and research
  bundle demos.
- [Pack authoring](docs/pack-authoring.md) — Crystal pack, type, behavior,
  tool, and spec conventions.
- [Demo server](docs/demo-server.md) — HTTP surface and deferred host seams.
- [Evolution design](docs/evolution-design.md) — governed self-modification:
  lifecycle, graph vocabulary, threat model, and acceptance bar.
- [LLM author design](docs/llm-author-design.md) — the keyless author
  boundary and drafting frame.
- [Soak runbook](docs/soak-runbook.md) — running and reading the LLM-author
  gate rotations.
- [Pack manifest specification](docs/manifest-spec.md) — the `manifest.toml`
  schema, content hash, and static gates.
- [MCP](docs/mcp.md) — outbound governed tool consumption and the inbound
  server shape.
- [Security](docs/security.md) — untrusted content and prompt-injection
  containment.
- [Long-term memory](docs/long-term-memory.md) — conversation-driven memory,
  curation, and hybrid recall.
- [Development](docs/development.md), [testing](docs/testing.md),
  [coding guidelines](docs/coding-guidelines.md), and
  [PR workflow](docs/pr-workflow.md) — contributor workflow and parity gates.

## Development

```bash
git submodule update --init --recursive
shards install
crystal tool format --check src spec
ameba src spec
crystal spec
```

The parity inventory and roadmap are maintained in
[plans/parity.md](plans/parity.md).

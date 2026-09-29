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
key is never required for the documented baseline.

```crystal
require "chronicle-packs"

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant
runtime.run_until_idle

puts graph.objects(type: "agent_profile").size
```

Use `build_messaging_assistant`, `build_email_assistant`, or
`build_research_assistant` for the corresponding preset. For a durable
application runtime, construct a `Chronicle::Runtime` over your chosen event
store, then use `Bundles.load_assistant_packs` or load pack declarations in the
required order. See [Bundles](docs/bundles.md).

## Documentation

- [Concepts](docs/concepts.md) — event-sourced graph coordination, pack
  boundaries, deterministic floor, and governance.
- [Architecture](docs/architecture.md) — Crystal module layout and runtime
  boundaries.
- [Pack catalog](docs/packs.md) — every ported pack grouped by role.
- [Bundles](docs/bundles.md) — included packs and configuration seams.
- [Pack authoring](docs/pack-authoring.md) — Crystal pack, type, behavior,
  tool, and spec conventions.
- [Demo server](docs/demo-server.md) — HTTP surface and deferred host seams.
- [Development](docs/development.md), [testing](docs/testing.md), and
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

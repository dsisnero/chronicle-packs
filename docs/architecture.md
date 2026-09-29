# Architecture

`chronicle-packs` maps the vendor's pack architecture onto Chronicle and
Crystal. A pack owns a narrow graph surface—object types, relation types,
reactive behaviors, settings, and tools. It coordinates with other packs only
through durable graph-visible facts.

```text
input / tool / scheduled tick
            |
            v
  GraphProjection emits durable event
            |
            v
 Chronicle::Runtime dispatches PackBehavior
            |
            v
 object / relation / result written by another pack
```

There is no pack-level coordinator and a domain pack must not call another
domain pack's private helper to make progress. Load order establishes required
types and behaviors; events establish runtime coordination.

## Crystal structure

The public entry point is `src/chronicle-packs.cr`. A conventional pack is
split beneath `src/chronicle_packs/<name>/`:

- `pack.cr` declares `Chronicle::Packs::Pack` through the pack DSL.
- `object_types.cr` and `relation_types.cr` define durable graph shapes.
- `behaviors.cr` contains annotated reactive handlers.
- `tools.cr` contains deterministic graph-facing operations.
- `settings.cr` defines a typed `JSON::Serializable` configuration object.

The port uses typed Crystal structs/classes at the graph boundary. Closed
vendor literals are Crystal enums; genuinely provider-owned payloads remain
open `Hash(String, JSON::Any)` values. See [coding guidelines](coding-guidelines.md).

## Runtime and provider boundaries

Chronicle owns event storage, runtime dispatch, frames, forks, promotion, and
recorded model/tool transport. This library owns pack policy. The Tool Gateway
records a capability call before action; Semantic Extraction verifies recorded
model output before it becomes annotations; Memory Gateway keeps graph objects
authoritative while embeddings remain optional recall acceleration.

The Crystal demo server is an HTTP wrapper over a bundle runtime. Its portable
default is an in-memory store. Vendor integrations requiring a hosted MCP
client, managed OAuth source, background tick driver, or deployment-owned
persistent storage remain explicit host seams. See [Demo server](demo-server.md)
and [intentional divergences](../plans/parity.md#intentional-divergences).

## Source of truth

Vendor behavior is authoritative at the revision recorded in the root README.
The generated source and test manifests are evidence of coverage; the curated
[parity roadmap](../plans/parity.md) explains feature boundaries and intentional
Crystal/host differences.

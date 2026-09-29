# chronicle-packs documentation

This is the Crystal equivalent of the vendor root, pack, bundle, contributor,
and test guides. It documents the port's public behavior and calls out where a
Python deployment instruction has no portable Crystal counterpart.

## Start here

- [Concepts](concepts.md) — graph coordination, Core, layered packs, and
  deterministic operation.
- [Architecture](architecture.md) — runtime ownership and source layout.
- [Pack catalog](packs.md) — all ported surfaces and their responsibility.
- [Bundles](bundles.md) — assembled assistant runtimes.
- [Demo server](demo-server.md) — HTTP API and host-owned boundaries.

## Build and contribute

- [Development](development.md)
- [Testing](testing.md)
- [Pack authoring](pack-authoring.md)
- [Coding guidelines](coding-guidelines.md)
- [PR workflow](pr-workflow.md)

## Parity

The pinned vendor checkout is `../vendor/activegraph-packs`. The feature
roadmap and source/test ledgers live under [`../plans`](../plans/). A documented
intentional divergence is a deliberate Crystal or host boundary, not an
untracked omission.

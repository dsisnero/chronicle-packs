# Development

## Prerequisites

- Crystal >= 1.21.0

## Setup

```bash
shards install
```

`shard.lock` records the dependency resolution used by the port. Run `shards
update` only when intentionally updating dependencies, then run the full gates
and commit the resulting lockfile change with its compatibility evidence.

The upstream source-of-truth is a git submodule:

```bash
git submodule update --init --recursive
```

## Quality gates

```bash
crystal tool format --check src spec   # check formatting
ameba src spec                          # lint
crystal spec                            # run tests
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache crystal build --no-codegen src/chronicle-packs.cr
```

The build check catches public-surface compilation errors without leaving a
binary in the repository. `CRYSTAL_CACHE_DIR` is optional; it keeps local
compiler artifacts contained when a developer wants a project-local cache.

## Parity workflow

Before porting a vendor behavior, find its source and test in the pinned
checkout, add or update a focused Crystal spec, and preserve the observable
contract. Then update both ledgers when their status changes:

- `plans/inventory/python_port_inventory.tsv` — source/API items.
- `plans/inventory/python_test_parity.tsv` — vendor test cases and their
  Crystal characterization specs.
- `plans/parity.md` — user-facing feature-sized roadmap and documented
  intentional divergences.

An intentional divergence needs a vendor reference and a concrete reason: a
Crystal language boundary, a Chronicle host-owned concern, or an unavailable
external service. It is not a synonym for unimplemented behavior.

Upstream source is at `vendor/activegraph-packs/` (git submodule, pinned).

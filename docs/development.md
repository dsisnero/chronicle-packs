# Development

## Prerequisites

- Crystal >= 1.21.0

## Setup

```bash
shards install
```

The upstream source-of-truth is a git submodule:

```bash
git submodule update --init --recursive
```

## Quality gates

```bash
crystal tool format --check src spec   # check formatting
ameba src spec                          # lint
crystal spec                            # run tests
```

## Parity workflow

See `plans/parity.md` for the feature roadmap and
`plans/inventory/python_port_inventory.tsv` for per-item porting status.

Upstream source is at `vendor/activegraph-packs/` (git submodule, pinned).

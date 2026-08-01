# CLAUDE.md

# chronicle-packs

Crystal port of the ActiveGraph pack library. Upstream source-of-truth is the
pinned git submodule at `vendor/activegraph-packs/`
(revision `6639a5385518ad49f74813373c85cf96eff9adc0`).

## Commands

```bash
shards install                          # install dependencies
shards update                           # update dependencies
crystal tool format --check src spec    # check formatting
crystal tool format src spec            # apply formatting
ameba src spec                          # lint
crystal spec                            # run tests
```

## Principles

- Upstream (activegraph-packs) behavior is the source of truth.
- Port behavior first; Crystal idioms only where semantics stay unchanged.
- Upstream tests and fixtures are normative; do not weaken them.
- Parity inventory under `plans/inventory/` tracks port status; `plans/parity.md` is the roadmap.

## Relevant docs

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Coding guidelines](docs/coding-guidelines.md)
- [Testing](docs/testing.md)
- [PR workflow](docs/pr-workflow.md)

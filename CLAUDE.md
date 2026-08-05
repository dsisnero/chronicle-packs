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
- **Typed by default:** domain types (object types, tool parameters, event
  payloads, projection state, behaviors' object reads) are `struct`s (or
  classes where genuinely mutable/resource-owning) with `JSON::Serializable`
  and explicit initializers — never `JSON.parse(...).as_h` chains. Raw
  `Hash(String, JSON::Any)` only for genuinely open-shaped data: provider
  payloads, `metadata`, and `service_extensions`. Use
  `@[JSON::Field(converter: ...)]` for typed fields like ISO-8601 `Time`.
- **Immutable structs use `record`:** declare simple immutable structs with
  the `record Name, field : Type = default, ... do include JSON::Serializable
  end` form — it generates getters, defaults, the initializer, and
  `copy_with`. For bool fields, `record`'s plain getters trip ameba
  `Naming/QueryBoolMethods` for `is_`/`has_` prefixes AND bare bool-noun
  names (`passed`, `fixture`, `enabled`, ...) — so in `record` structs name
  bools with compound/descriptive words (`volume_passed`, `allow_either`)
  and keep the upstream JSON key via `@[JSON::Field(key: "is_fixture")]`.
  In plain structs (custom initializer or parse-only), use `getter? field`
  which is ameba-clean and needs no key annotation. When a plain struct
  needs `copy_with`, include `Chronicle::Packs::CopyWith` and declare
  `define_copy_with(field1, field2, ...)` (all fields as named params
  defaulting to the current ivar values) — no `JSON.parse(...).as_h` merge
  patches.
- **Closed string sets are enums:** for validated, closed `Literal` sets
  (source_category, connection_path, surface_status, replay_mode, risk
  class, maintenance mode, ...) use a Crystal `enum`. Non-flags enums
  serialize as the member name via `String#underscore` — so name members
  as the CamelCase of the upstream string (`AiActivity` → `"ai_activity"`)
  and `to_json`/`from_json` round-trip to the exact upstream value with no
  converter, while `parse?` gives validation, `.each`/question methods give
  iteration and case-matching. Keep `String` only for genuinely open values
  (`metadata`, memory `category`, free-form labels). Values that do NOT
  round-trip through underscore (e.g. `action_class` `"R0"` → `"r0"`) need
  an explicit `wire`/`from_wire` converter or a `@[JSON::Field(converter:)]`.

## Relevant docs

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Coding guidelines](docs/coding-guidelines.md)
- [Testing](docs/testing.md)
- [PR workflow](docs/pr-workflow.md)

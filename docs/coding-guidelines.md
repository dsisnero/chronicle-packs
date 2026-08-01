# Coding guidelines

## Porting rules

- Upstream `activegraph-packs` behavior is the source of truth.
- Port behavior first; Crystal idioms only where semantics stay unchanged.
- Preserve parameter order, edge cases, and invalid-input behavior.
- Do not weaken upstream tests or fixtures to make the port look green.
- Never change behavior in the name of being "more idiomatic".

## Types

- Use `Bytes` (`Slice(UInt8)`) for binary semantics, never `String`.
- Use explicit numeric widths when signedness or range matters.
- Preserve data-structure and boundary semantics when behavior depends on them.

## Graph model

- Object schemas map to Crystal structs/classes with the same field names,
  defaults, and constraints (bounds on confidence/score 0.0–1.0, literal
  status/priority enums).
- Relation types keep their `source_types` / `target_types` constraints.
- Deterministic behaviors must run without an LLM or API key — the deterministic
  floor is a supported mode, not an error.

## Errors

- Use Crystal-native `Exception` types matching upstream failure semantics.

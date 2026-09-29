# Coding guidelines

## Porting rules

- Upstream `activegraph-packs` behavior is the source of truth.
- Port behavior first; Crystal idioms only where semantics stay unchanged.
- Preserve parameter order, edge cases, and invalid-input behavior.
- Do not weaken upstream tests or fixtures to make the port look green.
- Never change behavior in the name of being "more idiomatic".

## Types

- Model closed graph payloads with `struct`/`class` plus
  `JSON::Serializable` and explicit initializers. Do not spread
  `JSON.parse(...).as_h` chains through a domain behavior.
- Use `record` for simple immutable payloads. Use the pack's `CopyWith` macro
  when a custom-initialized payload needs immutable updates.
- Model validated closed string sets as Crystal `enum`s. Keep `String` and
  `Hash(String, JSON::Any)` for truly open provider payloads, metadata, and
  service extensions only.
- Use `@[JSON::Field]` converters for wire shapes such as timestamps; preserve
  vendor JSON field names even where the Crystal member spelling differs.
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

## Tools and embeddings

- A model-facing capability is a `CrigGatewayTool`, not a raw handler. Its
  callback must use the shared `ToolGateway` policy, audit, approval, and
  result state machine before an action can execute.
- Keep Crig responsible for provider transport and tool-call parsing; keep
  governance in Chronicle packs. Generic agent hooks may emit telemetry but
  must not duplicate gateway audit records.
- Bind embedding services per graph through `MemoryGateway::Backend`. Memory
  remains durable in the graph; lexical retrieval is always available, and
  vectors can only improve recall. Never compare embeddings from different
  model/version spaces.

## Pack boundaries

- Keep vendor behavior as the contract. A Crystal-native implementation may
  change representation, never observable semantics without an explicit,
  documented divergence.
- Put runtime, database, OAuth, scheduler, and external-provider policy in
  an explicit host seam when it cannot be safely owned by the pack. Fail
  closed or return the documented unavailable result—do not invent a local
  substitute behavior.
- Keep pack declarations, object/relation types, behaviors, settings, and
  fixtures near the pack that owns them; avoid hidden cross-pack mutation.

## Errors

- Use Crystal-native `Exception` types matching upstream failure semantics.

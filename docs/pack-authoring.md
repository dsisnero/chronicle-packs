# Pack authoring

Use `src/chronicle_packs/template/` as the Crystal starting point. The vendor's
`packs/_template` is conceptual guidance only: Crystal packs use typed structs,
the pack DSL, annotations, and specs rather than Python modules, decorators,
Pydantic models, or `pyproject.toml` entry points.

## Layout

```text
src/chronicle_packs/my_pack/
  pack.cr             # requires parts and declares the Pack
  settings.cr         # typed JSON::Serializable settings
  object_types.cr     # typed durable object structs/classes
  relation_types.cr   # constrained relation declarations
  behaviors.cr        # annotated reactive handlers
  tools.cr            # deterministic graph-facing operations
spec/chronicle_packs/my_pack_spec.cr
```

Require the pack entry point from `src/chronicle-packs.cr`; there is no
Python-style package-discovery entry point to edit.

## Rules

- Define domain data as typed structs/classes with `JSON::Serializable`.
  Reserve `Hash(String, JSON::Any)` for provider payloads and open metadata.
- Use Crystal enums for closed vendor literals and preserve wire names.
- Declare behavior trigger/filter/create information with the pack annotation
  DSL. Behaviors coordinate through graph writes, not direct inter-pack calls.
- A model-facing capability must be a `ToolGateway` proxy. Never register a raw
  provider handler with a model tool set.
- Keep secrets out of objects, logs, prompts, and model context. Use secret
  references and gateway-time injection.
- Write a focused spec before changing vendor-backed behavior. A deterministic
  test must not need a network key or ambient provider configuration.

## Completion checklist

- [ ] Relevant vendor test behavior has an equivalent Crystal spec.
- [ ] `crystal tool format --check src spec`, `ameba src spec`, and
      `crystal spec` pass.
- [ ] Parity ledger and roadmap are updated for a vendor-port feature.
- [ ] The feature is committed atomically with a `port:` subject.

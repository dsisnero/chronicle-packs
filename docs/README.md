# chronicle-packs documentation

This is the Crystal equivalent of the vendor root, pack, bundle, contributor,
and test guides. It documents the port's public behavior and calls out where a
Python deployment instruction has no portable Crystal counterpart.

## Start here

- [Concepts](concepts.md) — graph coordination, Core, layered packs, and
  deterministic operation.
- [Architecture](architecture.md) — runtime ownership and source layout.
- [Pack catalog](packs.md) — all ported surfaces and their responsibility.
- [Bundles](bundles.md) — assembled assistant runtimes and the walkthrough.
- [Demo server](demo-server.md) — HTTP API and host-owned boundaries.
- [Examples](../examples/README.md) — runnable assistant, email, and research
  bundle demos.

## Using the library from Crystal

A bundle gives you a `{store, graph, runtime}` triple. React to input by
calling a pack's `*_fn` helper with the graph, draining behaviors, then reading
durable state:

```crystal
require "chronicle-packs"

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant
Chronicle::Packs::Chat.submit_chat_input_fn(
  graph, user_ref: "alice@example.com", content: "hi", session_id: "s1",
)
runtime.run_until_idle

graph.objects(type: "chat_turn") # durable typed objects
store.iter_events                # causal, replayable event log
```

Objects and relations are the integration boundary; behaviors react to events
and write more graph state. The full program, with printed output, is
[`examples/assistant_chat.cr`](../examples/assistant_chat.cr) (`crystal run
examples/assistant_chat.cr`).

## Reference

- [Pack manifest specification](manifest-spec.md) — the `manifest.toml` schema,
  both hash layers, and the two-way surface contract.
- [MCP](mcp.md) — outbound governed tool consumption and the inbound
  assistant-as-server shape.
- [Evolution design](evolution-design.md) — governed self-modification:
  lifecycle stages, graph vocabulary, threat model, and acceptance bar.
- [LLM author design](llm-author-design.md) — the keyless author boundary,
  drafting context, and author frame.
- [Soak runbook](soak-runbook.md) — running and reading the LLM-author gate
  rotations.
- [Security](security.md) — untrusted content and prompt-injection
  containment.
- [Long-term memory](long-term-memory.md) — conversation-driven memory,
  curation, and hybrid recall.

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

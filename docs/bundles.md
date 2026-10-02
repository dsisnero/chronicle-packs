# Bundles

A bundle is a tested, named load order—not a pack and not an ontology. The
builders return `{store, graph, runtime}` using a `MemoryEventStore` and the
deterministic `BundleModel`; applications needing durable storage construct
their own runtime and call the corresponding `load_*_packs` helper.

| Builder | Included packs |
| --- | --- |
| `build_assistant` | core, tool_gateway, secrets, memory_gateway, agent_profile, identity_auth, communication, schedule, chat |
| `build_messaging_assistant` | assistant plus telegram and whatsapp |
| `build_email_assistant` | assistant plus email and entity |
| `build_research_assistant` | core, tool_gateway, memory_gateway, communication, chat, research |

```crystal
require "chronicle-packs"

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant(
  identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
    %({"owner_identifiers":["owner@example.com"]}),
  ),
)
runtime.run_until_idle
```

Settings are typed per pack and optional. They are `JSON::Serializable`
structs, so construct them with `from_json` (or a pack-provided initializer
where one exists), not a `JSON.parse(...).as_h` merge patch. Passing no
override preserves the pack default. A non-empty chat tool allow-list is
converted to runtime gateway proxies during bundle construction, so
model-facing tools keep the gateway's policy and audit trail.

## Run the walkthroughs

[`examples/`](../examples/README.md) holds Crystal ports of upstream
`bundles/examples/`, one per bundle:

```bash
crystal run examples/assistant_chat.cr      # build_assistant
crystal run examples/email_assistant.cr     # build_email_assistant
crystal run examples/research_assistant.cr  # build_research_assistant
```

Each builds its bundle, drives it with deterministic input, drains the
reactive behaviors, and prints the durable graph objects and the event log.
The assistant flow is `chat_input` → `comm_message` + `chat_session` +
`chat_turn` → model response, with `identity_auth` resolving the sender to a
`principal`; the deterministic `BundleModel` answers without a provider key.
After `run_until_idle`, inspect graph state with
`graph.objects(type: "...")` / `graph.all_objects` and the causal history with
`store.iter_events`. For durable persistence, back the runtime with a
`Chronicle::SQLiteEventStore` (see [Demo server](demo-server.md) for the HTTP
surface).

## Durable host runtime

`build_*` is a runnable baseline, not a deployment persistence policy. A host
that needs a SQLite-backed Chronicle runtime, provider model, or background
scheduling owns those resources and loads the bundle onto that runtime:

```crystal
# rt is an application-owned Chronicle::Runtime with its graph attached.
Chronicle::Packs::Bundles.load_assistant_packs(rt)
```

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

identity = Chronicle::Packs::IdentityAuth::IdentitySettings.new(
  owner_identifiers: ["owner@example.com"],
)
store, graph, runtime = Chronicle::Packs::Bundles.build_assistant(
  identity_settings: identity,
)
runtime.run_until_idle
```

Settings are typed per pack and optional. Passing no override preserves the
pack default. A non-empty chat tool allow-list is converted to runtime gateway
proxies during bundle construction, so model-facing tools keep the gateway's
policy and audit trail.

## Durable host runtime

`build_*` is a runnable baseline, not a deployment persistence policy. A host
that needs a SQLite-backed Chronicle runtime, provider model, or background
scheduling owns those resources and loads the bundle onto that runtime:

```crystal
# rt is an application-owned Chronicle::Runtime with its graph attached.
Chronicle::Packs::Bundles.load_assistant_packs(rt)
```

# chronicle-packs

Crystal port of https://github.com/yoheinakajima/activegraph-packs
— the official pack library for the ActiveGraph reactive object-graph runtime.

Pinned upstream revision: `6639a5385518ad49f74813373c85cf96eff9adc0` (git submodule at `vendor/activegraph-packs/`).

The upstream library composes 19 packs plus a bridge pack into a coherent,
auditable assistant architecture. Packs coordinate emergently: one pack writes
an object, the write is an event, and the event triggers a behavior in another
pack. This port mirrors that tiered model in Crystal.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     chronicle-packs:
       github: dsisnero/chronicle-packs
   ```

2. Run `shards install`

## Usage

```crystal
require "chronicle-packs"
```

## Development

```bash
shards install
crystal tool format --check src spec
ameba src spec
crystal spec
```

See `plans/parity.md` for the porting roadmap.

## Upstream README Highlights

The upstream is a Python pack library. Its packs split into:

- **Core Pack** (`packs/core`) — the universal substrate: 7 object types
  (source, observation, task, action, artifact, memory_candidate, evaluation)
  and 7 relation types, depending on nothing.
- **Layered packs** — infrastructure (tool_gateway, secrets, memory_gateway,
  identity_auth, agent_profile, entity), communication (communication, chat,
  email, schedule), and domain verticals (research, codebase, team_ops,
  meeting). Domain packs map their outputs back to Core primitives.
- **Transport adapters** — telegram, whatsapp, gmail, mcp, composio, evolution.
- **Importers** — format adapters emitting strict `acquired_item` /
  `acquired_content` handoffs.
- **Bundles** — preset pack lists with factory functions (assistant,
  messaging_assistant, email_assistant, research_bundle).

Everything runs with zero API keys: the deterministic floor serves every facet
of extraction, memory, and behavior. Providing an LLM key is an upgrade, never
a requirement.

## Contributing

1. Fork it (<https://github.com/dsisnero/chronicle-packs/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Dominic Sisneros](https://github.com/dsisnero) - creator and maintainer

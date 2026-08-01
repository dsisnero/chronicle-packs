# Architecture

`chronicle-packs` is a Crystal port of the `activegraph-packs` library — the
official pack library for the ActiveGraph reactive object-graph runtime.

## Upstream model

Upstream packs are Python modules. Each pack directory exports:

- `__init__.py` — a `Pack(...)` object and a settings class
- `object_types.py` — Pydantic schemas plus `OBJECT_TYPES` / `RELATION_TYPES` lists
- `behaviors.py` — `@behavior` / `@llm_behavior` reactive handlers
- `tools.py` — `@tool` decorated callable capabilities
- `settings.py` — Pydantic settings (all fields must have defaults)
- `fixtures/` — deterministic `.yaml` scenarios, no API key required
- `manifest.toml` — declarative surface: object types, relation types, behaviors, tools, settings schema

Coordination is emergent: one pack writes an object, the write is an event, and
the event triggers a behavior in another pack. No central orchestrator.

## Port structure

The Crystal port mirrors the tiered pack model:

- Core pack (`src/chronicle_packs/core.cr`) — 7 object types, 7 relation types, deterministic behaviors
- Infrastructure packs — tool_gateway, secrets, memory_gateway, identity_auth, agent_profile, entity, etc.
- Communication packs — communication, chat, email, schedule
- Domain packs — research, codebase, team_ops, meeting
- Transport adapters — telegram, whatsapp, gmail, mcp, composio, evolution
- Importers — local_files, chatgpt_export, claude_export, assistant_*, public_presence
- Bundles — assistant, messaging_assistant, email_assistant, research_bundle

## Source of truth

Upstream is a pinned git submodule at `vendor/activegraph-packs/`
(revision 6639a5385518ad49f74813373c85cf96eff9adc0). Upstream behavior,
tests, and fixtures are normative.

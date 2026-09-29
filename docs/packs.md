# Pack catalog

Every entry below is a Crystal `Chronicle::Packs::Pack` surface (or an
explicit adapter around one), grouped by responsibility. The vendor's
per-pack READMEs are guidance; this catalog is the Crystal equivalent and links
to source instead of duplicating Python module paths.

| Area | Packs | Responsibility |
| --- | --- | --- |
| Core | `core` | Universal source, observation, task, action, artifact, memory-candidate, and evaluation primitives. |
| Governance | `tool_gateway`, `secrets`, `identity_auth`, `agent_profile` | Governed capabilities, secret references, principals/roles, and assistant profile. |
| Memory and extraction | `memory_gateway`, `activity_normalizer`, `semantic_extraction`, `attention`, `subject_profile`, `entity`, `skills`, `eval_outcome` | Evidence, annotations, durable memory, attention, subject state, entities, skills, and outcome evaluation. |
| Communication | `communication`, `chat`, `email`, `schedule`, `telegram`, `whatsapp` | Channel-neutral messages plus conversational, mail, scheduled, and transport adapters. |
| Connectors | `usage`, `connector_control`, `composio`, `gmail`, `mcp`, `public_presence` | Connector lifecycle, service profiles, governed hosted routes, Gmail, MCP, and public-web acquisition. |
| Domain | `research`, `codebase`, `team_ops`, `meeting` | Research, engineering, team workflow, and meeting concepts mapped to Core. |
| Importers | `local_files`, `chatgpt_export`, `claude_export`, `assistant_self_summary`, `assistant_local_sessions` | Deterministic ingestion into the acquired-content/evidence path. |
| Evolution | `evolution` | Authored Crystal candidate gates, isolated trials, adoption, boot recovery, and soak evidence. |
| Support | `bridges`, `template`, `fixtures`, `doctor`, `preflight`, `manifest_tools` | Cross-pack bridge, template, scenarios, diagnostics, compatibility, and manifests. |

## Discovering a pack surface

The declaration is authoritative for object types, relation types, behaviors,
tools, and settings. Use a pack's source and corresponding spec together:

```text
src/chronicle_packs/<pack>/pack.cr
src/chronicle_packs/<pack>/{object_types,relation_types,behaviors,tools,settings}.cr
spec/chronicle_packs/<pack>_spec.cr
```

Some compact packs live in a single file, notably `core.cr`, `bundles.cr`,
`doctor.cr`, and `demo_server.cr`. Source comments identify their vendor
counterparts and pinned revision.

Core has no pack dependency. Layered packs load after the surfaces they need.
Use bundle builders for tested common orders. Optional integrations must fail
closed or degrade to documented deterministic behavior when absent; they must
not create a hidden global dependency.

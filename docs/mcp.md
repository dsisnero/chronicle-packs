# MCP: the assistant as tool consumer and as tool

The MCP pack (`src/chronicle_packs/mcp/`) is bidirectional. Outbound, the
assistant consumes any MCP server's tools — pre-governed by the Tool Gateway.
Inbound, the assistant **is** an MCP server: another agent (a Claude session,
an orchestrator, a sibling assistant) can chat with it, search its memory, or
invoke selected skills, under token auth and role-scoped exposure rules. Zero
new dependencies in either direction: the protocol layer is the Crystal stdlib
(`client.cr`), and the inbound gateway speaks plain-JSON streamable HTTP.

The pack's declared surface is 3 object types (`mcp_server`, `mcp_exposure`,
`mcp_access`), zero relations/behaviors/tools, the `MCPSettings` schema, and
the `mcp.set_exposure` capability (`risk_class = "high"`, `action_class =
"R4"`). See [Pack manifest specification](manifest-spec.md) and
[MCP settings](https://github.com/dsisnero/chronicle-packs) source for the
exact fields.

---

## Outbound: governed breadth

```crystal
require "chronicle-packs"

client = Chronicle::Packs::MCP.make_client(
  "http",
  url: "https://mcp.example.com/mcp",
  headers: {"Authorization" => "Bearer ..."},
)
keys = Chronicle::Packs::MCP.connect_and_register("example", client, graph: graph)
# => ["mcp_example.search", "mcp_example.create_issue", ...]
```

Each discovered tool becomes a gateway capability (`mcp_<server>.<tool>`)
with a dynamically built parameter schema, so it can join a tool
allow-list like any local capability. The governance properties this buys,
none of which raw MCP has:

- **Untrusted by default.** Discovered tools get risk class `high` —
  approval-required under the default policy. A model calling one gets
  `held_for_approval`; the owner resolves it in `/approvals`. Promote
  individual tools deliberately: `tool_risk_overrides: {"search" => "low"}`.
- **Presumed outward-facing.** Discovered tools also get canonical
  `action_class` `R3` (ADR 0016) — a SEPARATE dimension from the risk
  label, never derived from it — which keeps them ineligible for
  ceiling-based auto-approval at every ceiling. Assign a lower class
  per tool, explicitly: `tool_action_class_overrides: {"search" => "R0"}`.
- **Recorded.** Every call is a `capability_call` → `capability_result`
  pair in the graph, with the MCP caller/tool named.
- **Sanitized + injection-scanned.** MCP output flows through the same
  sanitizer and untrusted-content posture as every capability (see
  [security](https://github.com/yoheinakajima/activegraph-packs/blob/main/docs/security.md)),
  and reaches the model fenced as EXTERNAL CONTENT.

Configure outbound servers programmatically through `MCPSettings.servers`
(the Crystal replacement for the upstream `ACTIVEGRAPH_MCP_SERVERS` env
shape):

```crystal
settings = Chronicle::Packs::MCP::MCPSettings.new(servers: [
  {
    "name"                 => JSON::Any.new("example"),
    "transport"            => JSON::Any.new("http"),
    "url"                  => JSON::Any.new("https://mcp.example.com/mcp"),
    "tool_risk_overrides"  => JSON::Any.new({"search" => JSON::Any.new("low")}),
  } of String => JSON::Any,
])

results = Chronicle::Packs::MCP.register_configured_servers(settings, graph: graph)
# {server_name => [registered capability keys]}
```

An unreachable server is recorded as an `mcp_server` object with
`status="unreachable"` and skipped; it never blocks startup.

Transports: `http` (streamable HTTP, JSON or SSE responses,
`Mcp-Session-Id` echoed) and `stdio` (newline-delimited JSON-RPC over a
subprocess):

```crystal
client = Chronicle::Packs::MCP.make_client(
  "stdio",
  command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/data"],
)
```

The protocol layer is `MCPClient` and is deterministic given a transport:
`handshake`, `list_tools`, `call_tool`, and `call_tool_text`. `HttpTransport`
takes an injectable `http_post` proc so the deterministic specs never touch
the network; `StdioTransport` is best-effort and is not exercised by the
deterministic specs.

---

## Inbound: the assistant as an MCP server

The pack exposes a transport-agnostic `MCPGateway`. A host mounts it at its
own endpoint and points an MCP client (streamable HTTP) at it with a bearer
token:

```crystal
settings = Chronicle::Packs::MCP::MCPSettings.new(
  tokens: {"sekrit-token" => "you@example.com"},   # token => identifier
)
gateway = Chronicle::Packs::MCP::MCPGateway.new(
  -> { graph },
  settings,
  chat_fn: chat_fn,        # (message, user_ref, session_id) -> Hash
  memory_fn: memory_fn,    # (query, subject_ref, top_k) -> Array(Hash)
)

response = gateway.handle_jsonrpc(
  {
    "jsonrpc" => JSON::Any.new("2.0"),
    "id"      => JSON::Any.new(1),
    "method"  => JSON::Any.new("tools/list"),
  },
  "sekrit-token",
)
```

`MCPSettings.tokens` is the Crystal equivalent of the upstream
`ACTIVEGRAPH_MCP_TOKENS='token:identifier'` map. The identifier resolves to
an Identity/Auth principal whose role is the unit of exposure; the upstream
`ACTIVEGRAPH_OWNER` value maps to a principal registration through the
Identity/Auth pack, not to a setting.

What a caller can do is decided by three layers:

1. **Auth** — `MCP.resolve_caller` maps the bearer token to a caller
   identifier (`MCPSettings.tokens`); the identifier resolves to an
   Identity/Auth principal and the principal's **role** is the unit of
   exposure. Invalid token → refused. No token → anonymous → nothing.
   Another agent gets its own token and principal (role `collaborator`),
   so it is governed exactly like a human contact. With no principals
   registered at all, a valid token falls back to
   `MCPSettings.unverified_token_role` (default `owner` — single-user
   mode; set it to `""` to fail closed).
2. **Exposure** — graph-native `mcp_exposure` rules map surfaces to roles.
   Defaults (seeded by `MCP.ensure_default_exposures`): the owner sees
   everything (`chat`, `memory_search`, the exposed tools); everyone else
   sees nothing. Fail-closed: no enabled rule, no access. The latest rule
   per surface governs.
3. **Gateway policy** — exposed capabilities keep their risk classes; an
   inbound call to a high-risk skill is recorded and held for approval,
   not executed.

The surfaces:

| Tool | What it does |
|------|--------------|
| `chat` | Full chat pipeline with the caller's identity — reply gating, memory scoping, persona shaping, and the assistant's own governed tool use all apply. |
| `memory_search` | Memory recall **subject-scoped to the caller** (plus global memories) — one caller never reads another user's memories. |
| `catalog_search` | The capabilities **this caller's role can reach**, annotated with risk class, origin, and whether a call will be held for approval. Scoped on purpose: discovery for authorized callers, no reconnaissance over the rest of the registry. Own exposure surface (`catalog`, default owner-only). |
| exposed capabilities | `MCPSettings.expose_capabilities` keys (default empty; a host sets the list it wants exposed), run through the governed gateway path with `proposed_by="mcp:<caller>"`. |

Every inbound call — grant or refusal — is an `mcp_access` audit object.

### Editing exposure: config the agent can propose

Exposure rules are edited through the governed `mcp.set_exposure`
capability (risk `high`, action `R4`), registered by
`MCP.register_set_exposure_capability`. That means the assistant itself can
*propose* a change to its own MCP surface — "expose memory_search to my
research agent?" — and the proposal is a held `capability_call` the owner
approves or denies. Config edits are capability calls: recorded, approved,
auditable, revertible by a counter-edit.

```crystal
Chronicle::Packs::MCP.bound_graph = graph   # host seam: the gateway handler
                                            # receives only input_data
Chronicle::Packs::MCP.register_set_exposure_capability
# then propose via the gateway's LLM tool surface, or call directly after
# approval:
Chronicle::Packs::MCP.set_exposure_fn(
  graph, "memory_search", ["owner", "collaborator"],
  note: "research agent needs recall",
)
```

Humans can call `MCP.set_exposure_fn` directly or approve via `/approvals`.

### Trying it with curl

The upstream demo server mounts the endpoint at `POST /mcp`. **In this port
the demo server does not mount an MCP gateway**: `POST /mcp` returns
`503 "MCP gateway not initialized (no outbound MCP servers configured)"`
(`DemoServer::Handler#_handle_mcp`). Drive the gateway in-process instead, or
mount `MCPGateway` in your own HTTP host. The equivalent of the upstream
`curl` probe is:

```crystal
gateway.handle_jsonrpc(
  {
    "jsonrpc" => JSON::Any.new("2.0"),
    "id"      => JSON::Any.new(1),
    "method"  => JSON::Any.new("tools/list"),
  },
  "sekrit-token",
)
```

This is a documented host boundary, not missing pack behavior; see
[parity](../plans/parity.md#intentional-divergences).

---

## What v1 does not do

- **Token auth is shared-secret.** Fine for personal/agent-to-agent use;
  OAuth is deferred with the managed-auth work (secrets pack extension).
- **No SSE push on the inbound endpoint** — plain JSON responses only.
  Compatible with standard streamable-HTTP clients; server-initiated
  messages (sampling, notifications) are out of scope.
- **Outbound resources/prompts are not consumed** — tools only. The seam
  (`MCPClient#_rpc`) is there when a use case shows up.

## Crystal divergences

Ported behavior is faithful; these are the deliberate Crystal/host
differences. Full list in
[parity](../plans/parity.md#intentional-divergences):

- `MCPClient#handshake` is the protocol handshake; Crystal reserves
  `initialize` for the constructor.
- `schema_model_from_json_schema` returns a plain JSON Schema object
  instead of a dynamic Pydantic model; the MCP server revalidates on its
  side.
- `register_set_exposure_capability` uses the pack's `bound_graph` seam and
  records `updated_by: "gateway"`, because the ported gateway handler
  receives only `input_data`, not an `execution_context` with a graph or
  call id.
- The inbound endpoint is not mounted by the demo server (`/mcp` 503); the
  gateway is host-bound.
- Outbound discovery does not automatically join a chat allow-list: a host
  composes the allow-list it passes to `ToolGateway.llm_tools_for(graph,
  allow_list)`. Per-tool risk/action overrides remain explicit operator
  statements.

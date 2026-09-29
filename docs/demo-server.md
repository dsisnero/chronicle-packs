# Demo server

`Chronicle::Packs::DemoServer` is a Crystal `HTTP::Server` wrapper around the
assistant bundle. It is useful for inspecting the pack surface locally; it is
not a replacement for the vendor's React Inspector plus Express supervisor.

The host can call `Chronicle::Packs::DemoServer.main` directly. It uses
`ACTIVEGRAPH_PORT` when set and otherwise listens on `7788`. The handler is
testable in-process; see `spec/chronicle_packs/demo_server_spec.cr` for
request/response examples.

The server recognizes `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` as provider key
names but does not place their values in graph data. Approval routes can use
`ACTIVEGRAPH_APPROVAL_TOKEN`; when evolution is enabled, unauthenticated
approval is refused.

The vendor's managed OAuth, outbound MCP registration, persistent deployment
database, and autonomous schedule tick driver require application-owned
services. In this port those endpoints return their documented unavailable
shape until a host supplies the relevant seam. See [Architecture](architecture.md)
and the parity roadmap for the exact boundary.

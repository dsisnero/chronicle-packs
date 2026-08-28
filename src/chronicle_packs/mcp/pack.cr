require "chronicle"

require "./settings"
require "./object_types"
require "./client"
require "./registry"
require "./server"

# MCP Pack — bidirectional MCP. Outbound: servers' tools become governed
# Tool Gateway capabilities (approval-required by default); inbound: the
# assistant is itself an MCP server exposing chat, subject-scoped memory
# search, and selected capabilities — token-authenticated, role-gated by
# graph-native exposure rules, fully audited. Ported from upstream
# `packs/mcp` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::MCP
  include Chronicle::Packs::DSL

  # The graph the mcp.set_exposure capability handler operates on (host-bound
  # seam; the ported gateway handler receives only input_data, not an
  # execution_context with a graph).
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "mcp.set_exposure requires a bound graph (set MCP.bound_graph)"
    )
  end

  pack(
    name: "mcp",
    version: "0.3.0",
    description: "Bidirectional MCP: outbound servers' tools become governed Tool Gateway capabilities (approval-required by default); inbound, the assistant is itself an MCP server exposing chat, subject-scoped memory search, and selected capabilities — token-authenticated, role-gated by graph-native exposure rules, fully audited.",
    settings_schema: MCPSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(provider: "mcp", capability: "set_exposure", risk_class: "high", credential_ref: "", action_class: "R4"),
    ],
  )
end

require "chronicle"

require "./settings"
require "./client"
require "./tools"
require "./capabilities"

# Composio Pack — an optional thin Composio route: hosted Connect Links and
# per-service connection status. It never mirrors the Composio catalog or
# becomes a canonical service identity. No object or relation types; the two
# proposal tools surface owner-approved capability calls through the Tool
# Gateway. Ported from upstream `packs/composio` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::Composio
  include Chronicle::Packs::DSL

  pack(
    name: "composio",
    version: "0.1.0",
    description: "Optional thin Composio route: hosted Connect Links and per-service connection status. It never mirrors the Composio catalog or becomes a canonical service identity.",
    settings_schema: ComposioSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(
        provider: "composio",
        capability: "connections.link",
        risk_class: "high",
        credential_ref: "",
        action_class: "R4",
      ),
      Chronicle::Packs::CapabilityDecl.new(
        provider: "composio",
        capability: "connections.status",
        risk_class: "low",
        credential_ref: "",
        action_class: "R0",
      ),
    ],
  )
end

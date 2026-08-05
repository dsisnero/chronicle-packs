require "chronicle"

require "./settings"
require "./contracts"
require "./object_types"
require "./maintenance"
require "./operational"
require "./behaviors"
require "./tools"

# Connector Control Pack — neutral connector control-plane materializations.
# Ported from upstream `packs/connector_control`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no
# API key. Service/domain runs remain authoritative; these objects are
# idempotent adapter outputs.
module Chronicle::Packs::ConnectorControl
  include Chronicle::Packs::DSL

  pack(
    name: "connector_control",
    version: "0.1.0",
    description: "Neutral connector control-plane records: surface bindings, run observations, learning deltas, native views, operational policy, and maintenance requests.",
    settings_schema: ConnectorControlSettings,
  )
end

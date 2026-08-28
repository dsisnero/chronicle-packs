require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./hygiene"
require "./gating"
require "./behaviors"
require "./conversation"
require "./tools"

# Communication Pack — channel-neutral communication semantic layer. Ported
# from upstream `packs/communication` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Provides the legacy
# CommThread/CommMessage action layer plus the durable conversation-family
# contract with exact-span staged interpretation.
module Chronicle::Packs::Communication
  include Chronicle::Packs::DSL

  pack(
    name: "communication",
    version: "0.5.0",
    description: "Channel-neutral communication semantic layer. Provides the durable conversation-family contract with exact-span staged interpretation, plus the legacy CommThread/CommMessage action layer. Channel adapters own service mapping; semantic extraction owns bounded model execution.",
    settings_schema: CommunicationSettings,
  )
end

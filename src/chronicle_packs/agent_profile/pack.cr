require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./behaviors"
require "./tools"

# Agent Profile Pack — the assistant's identity, goals, personality, and
# standing instructions scoped by channel/audience. Ported from upstream
# `packs/agent_profile` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key.
module Chronicle::Packs::AgentProfile
  include Chronicle::Packs::DSL

  pack(
    name: "agent_profile",
    version: "0.1.1",
    description: "Agent identity, goals, standing instructions, and owner preferences. Context is behavior-scoped (not a global blob), filtered by channel and audience role.",
    settings_schema: AgentProfileSettings,
  )
end

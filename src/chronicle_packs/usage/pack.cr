require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Usage Pack — neutral connection, coverage, settlement, and activity facts.
# Ported from upstream `packs/usage` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key. The event log is the only projection input;
# queries require an explicit event-horizon id.
module Chronicle::Packs::Usage
  include Chronicle::Packs::DSL

  pack(
    name: "usage",
    version: "0.1.0",
    description: "Neutral connection, coverage, settlement, and activity fact schemas with explicit-horizon projections.",
    settings_schema: UsageSettings,
  )
end

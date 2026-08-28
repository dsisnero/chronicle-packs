require "chronicle"

require "./settings"
require "./behaviors"

# Bridges — pack layer connecting domain packs to the Core primitive layer
# without modifying the source packs. They subscribe to source-pack
# object.created events and emit Core equivalents with `derived_from`
# relations.
#
# diligence_core_bridge: maps Diligence pack objects to Core primitives so
# Diligence outputs appear alongside all other packs in the shared graph —
# document→source, claim→observation, memo→artifact, risk→evaluation.
# Non-destructive: never modifies the Diligence pack. Ported from upstream
# `packs/bridges` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::Bridges
  include Chronicle::Packs::DSL

  pack(
    name: "diligence_core_bridge",
    version: "0.1.1",
    description: "Maps Diligence pack objects to Core primitives so Diligence outputs appear alongside all other packs in the shared graph. document→source, claim→observation, memo→artifact, risk→evaluation. Non-destructive: does not modify the Diligence pack.",
    settings_schema: DiligenceCoreBridgeSettings,
  )
end

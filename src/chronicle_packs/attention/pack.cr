require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"
require "./tools"

# Attention Pack — semantic engagement observations and inspectable
# importance/source-trust vectors. Ported from upstream `packs/attention`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no
# API key, no pack dependencies.
module Chronicle::Packs::Attention
  include Chronicle::Packs::DSL

  pack(
    name: "attention",
    version: "0.3.0",
    description: "Semantic engagement observations plus explainable, scoped importance and source-trust vectors learned from recorded outcomes.",
    settings_schema: AttentionSettings,
  )
end

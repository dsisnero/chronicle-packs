require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Research Pack — paper ingestion, claim extraction, idea atom distillation,
# and hypothesis generation. Ported from upstream `packs/research`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# source (kind=research_paper) → Paper + Author(s) + Venue via paper_ingester;
# claims and idea atoms are extracted deterministically (mock stubs, no LLM);
# high-coherence atoms synthesize ResearchDirections that experiments test.
# Composes with Core (observations, sources, derived_from_source / grounds).
module Chronicle::Packs::Research
  include Chronicle::Packs::DSL

  pack(
    name: "research",
    version: "0.1.2",
    description: "Research paper ingestion, claim extraction, idea atom distillation, and hypothesis generation. All behaviors deterministic in v0.1 (mock LLM stubs). Provides 9 object types for scientific knowledge tracking.",
    settings_schema: ResearchSettings,
  )
end

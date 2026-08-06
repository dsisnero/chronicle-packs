require "chronicle"

require "./settings"
require "./facets"
require "./object_types"
require "./relation_types"
require "./extractor"
require "./engine"
require "./behaviors"
require "./procedures"
require "./tools"

# Semantic Extraction Pack — the shared annotation layer (ADR 0026). Ported
# from upstream `packs/semantic_extraction`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0). Slice 1: the
# deterministic zero-key floor (DeterministicExtractorV1), the seeded
# extraction_profile, and the eager annotate pipeline with cache idempotency.
# Deferred: procedures, the LLM extractor seam, selection requests, and the
# candidate projectors / promotion tools.
module Chronicle::Packs::SemanticExtraction
  include Chronicle::Packs::DSL

  pack(
    name: "semantic_extraction",
    version: "0.1.0",
    description: "The shared annotation layer: typed, source-anchored annotations under one provenance envelope.",
    settings_schema: SemanticExtractionSettings,
  )
end

require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./extractors"
require "./replay"
require "./behaviors"
require "./tools"

# Activity Normalizer Pack — provider-neutral evidence identity and
# deterministic candidate extraction. Ported from upstream
# `packs/activity_normalizer` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key. Slice 1 of the port: the object surface,
# StructureExtractor, replay-payload normalization, and the
# normalize_acquired_item behavior (with the legacy extraction opt-in).
# Deferred: replay artifact store, annotation extractor, the remaining
# behaviors, and the two graph tools.
module Chronicle::Packs::ActivityNormalizer
  include Chronicle::Packs::DSL

  pack(
    name: "activity_normalizer",
    version: "0.1.0",
    description: "Provider-neutral activity ingestion, evidence identity/revision ownership, and deterministic structure extraction.",
    settings_schema: ActivityNormalizerSettings,
  )
end

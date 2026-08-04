require "json"

module Chronicle::Packs::Entity
  # Configuration for Entity Pack. Controls extraction heuristics,
  # resolution thresholds, and merge candidate sensitivity. Ported from
  # upstream packs/entity/settings.py (EntitySettings).
  struct EntitySettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter extraction_min_confidence : Float64 = 0.6
    getter resolution_similarity_threshold : Float64 = 0.7
    getter merge_candidate_threshold : Float64 = 0.8
    getter? auto_accept_exact_identifier_match : Bool = true
    getter? extract_persons : Bool = true
    getter? extract_organizations : Bool = true
    getter? extract_urls_as_entities : Bool = false
    getter max_mentions_per_source : Int32 = 20
    # Shared-extraction migration (ADR 0026 step 4): the pack's own
    # source.created extraction is OFF by default.
    getter? extract_from_raw_sources : Bool = false
    getter? consume_entity_mention_annotations : Bool = true
  end
end

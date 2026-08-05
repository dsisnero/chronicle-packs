require "json"

module Chronicle::Packs::SemanticExtraction
  # Bounds and extractor selection for the shared annotation layer. Ported
  # from upstream packs/semantic_extraction/settings.py.
  struct SemanticExtractionSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = true
    getter extractor_id : String = "semantic.deterministic"
    getter extractor_version : String = "0.1.0"
    getter max_content_chars : Int32 = 32_000
    getter max_annotations_per_facet : Int32 = 50
    getter min_assertion_chars : Int32 = 15
    getter topic_tag_count : Int32 = 5
    getter? seed_default_profile : Bool = true
    getter default_profile_facets : Array(String) = Facets::DEFAULT_EAGER_FLOOR
    getter default_facets_by_source_category : Hash(String, Array(String)) = {"communication" => ["entity_mention", "question", "temporal_expression"]}
    getter? mint_profile_candidates : Bool = true
    getter? mint_memory_candidates : Bool = true
    getter? llm_upgrade_enabled : Bool = true
    getter llm_model : String = ""
    getter llm_record_dir : String = ""
    getter llm_max_output_tokens : Int32 = 4_096
    getter llm_timeout_seconds : Float64 = 60.0

    def initialize(
      @enabled : Bool = true,
      @extractor_id : String = "semantic.deterministic",
      @extractor_version : String = "0.1.0",
      @max_content_chars : Int32 = 32_000,
      @max_annotations_per_facet : Int32 = 50,
      @min_assertion_chars : Int32 = 15,
      @topic_tag_count : Int32 = 5,
      @seed_default_profile : Bool = true,
      @default_profile_facets : Array(String) = Facets::DEFAULT_EAGER_FLOOR,
      @default_facets_by_source_category : Hash(String, Array(String)) = {"communication" => ["entity_mention", "question", "temporal_expression"]},
      @mint_profile_candidates : Bool = true,
      @mint_memory_candidates : Bool = true,
      @llm_upgrade_enabled : Bool = true,
      @llm_model : String = "",
      @llm_record_dir : String = "",
      @llm_max_output_tokens : Int32 = 4_096,
      @llm_timeout_seconds : Float64 = 60.0,
    )
    end
  end
end

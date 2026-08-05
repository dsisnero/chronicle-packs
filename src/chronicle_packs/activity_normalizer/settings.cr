require "json"

module Chronicle::Packs::ActivityNormalizer
  # Configuration for the activity-normalizer pack. Ported from upstream
  # packs/activity_normalizer/settings.py (ActivityNormalizerSettings).
  struct ActivityNormalizerSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = true
    getter artifact_store_dir : String = ".activegraph/replay-artifacts"
    getter max_replay_payload_bytes : Int32 = 8 * 1024 * 1024
    getter default_extractor_id : String = "activity.structure"
    getter default_extractor_version : String = "0.1.0"
    getter default_extraction_config_id : String = "default"
    getter max_normalized_content_chars : Int32 = 16_000
    getter max_candidates_per_evidence : Int32 = 32
    getter max_candidate_chars : Int32 = 2000
    getter retention_policy : String = "source_default"
    getter encoding : String = "utf-8"
    getter? emit_custom_events : Bool = true
    # Shared-extraction migration (ADR 0026): the direct evidence→candidate
    # write path is OFF by default; the legacy path is an explicit opt-in.
    getter? legacy_extraction_enabled : Bool = false
    getter? select_shared_extraction : Bool = true
    getter? compat_candidate_projectors : Bool = true
  end
end

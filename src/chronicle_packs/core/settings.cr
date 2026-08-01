require "json"

module Chronicle::Packs::Core
  # Configuration for Core Pack v0.1. All fields have defaults — Core
  # works with zero configuration.
  #
  # Ported from upstream packs/core/settings.py (CoreSettings). The
  # upstream Pydantic field bounds (0.0..1.0 confidence, 1..100 max
  # observations) are documented but not runtime-enforced here.
  struct CoreSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    # Minimum confidence threshold for extracted observations; below this
    # they are still created but tagged low_confidence=true.
    getter observation_min_confidence : Float64 = 0.5

    # Minimum word-overlap ratio for task_linker to create a 'produces'
    # relation between an observation and an existing task.
    getter task_link_similarity_threshold : Float64 = 0.6

    # Maximum observations the observation_extractor creates per source.
    getter max_observations_per_source : Int32 = 10

    # If true, memory_candidate objects are auto-accepted on creation.
    # In production Memory Gateway handles acceptance; this is for demos.
    getter? auto_accept_memory_candidates : Bool = false
  end
end

require "json"

module Chronicle::Packs::Research
  # Settings for the Research Pack. Ported from upstream
  # packs/research/settings.py (ResearchSettings). Controls claim/idea
  # extraction volume and direction-synthesis gating.
  struct ResearchSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter min_idea_novelty_score : Float64 = 0.4
    getter min_coherence_for_hypothesis : Float64 = 0.5
    getter max_ideas_per_paper : Int32 = 5
    getter max_claims_per_paper : Int32 = 8
    getter? auto_synthesize_directions : Bool = true
    getter min_ideas_for_direction : Int32 = 2

    def initialize(
      @min_idea_novelty_score : Float64 = 0.4,
      @min_coherence_for_hypothesis : Float64 = 0.5,
      @max_ideas_per_paper : Int32 = 5,
      @max_claims_per_paper : Int32 = 8,
      @auto_synthesize_directions : Bool = true,
      @min_ideas_for_direction : Int32 = 2,
    )
    end
  end
end

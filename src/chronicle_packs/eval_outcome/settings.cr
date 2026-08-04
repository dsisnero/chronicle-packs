require "json"

module Chronicle::Packs::EvalOutcome
  # Configuration for canonical outcome capture and reliability projection.
  # Ported from upstream packs/eval_outcome/settings.py (EvalOutcomeSettings).
  struct EvalOutcomeSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = true
    getter supported_retrieval_multiplier : Float64 = 1.0
    getter weak_retrieval_multiplier : Float64 = 0.75
    getter harmful_retrieval_multiplier : Float64 = 0.1
    getter stale_retrieval_multiplier : Float64 = 0.25
  end
end

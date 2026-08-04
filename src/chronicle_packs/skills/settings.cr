require "json"

module Chronicle::Packs::Skills
  # Configuration for the skills lifecycle. Ported from upstream
  # packs/skills/settings.py (SkillsSettings).
  struct SkillsSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = true
    # Allow candidate versions in trial runs; real runs require promotion.
    getter? allow_candidate_trials : Bool = true
    getter default_candidate_version : String = "0.1.0"
  end
end

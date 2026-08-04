require "json"

module Chronicle::Packs::AgentProfile
  # Configuration for Agent Profile Pack. Sensible defaults so the pack
  # works without configuration. Ported from upstream
  # packs/agent_profile/settings.py (AgentProfileSettings).
  struct AgentProfileSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter default_agent_name : String = "Assistant"
    getter default_mission : String = "Help the owner accomplish their goals efficiently."
    getter default_tone : String = "neutral"
    getter default_verbosity : String = "balanced"
    getter default_formality : String = "neutral"
    getter owner_name : String? = nil
    getter? expose_mission_to_external : Bool = false
    getter max_standing_instructions : Int32 = 20
    getter max_active_goals : Int32 = 10
    getter default_profile_id : String? = nil
    getter? auto_trigger_on_auth_context : Bool = true
    getter? auto_trigger_on_frame : Bool = true
  end
end

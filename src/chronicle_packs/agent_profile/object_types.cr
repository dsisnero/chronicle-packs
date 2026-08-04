require "json"

module Chronicle::Packs::AgentProfile
  # Agent Profile object types. Ported from upstream
  # packs/agent_profile/object_types.py. No global system-prompt blobs —
  # context is scoped per behavior, filtered by channel and audience role.

  # The assistant's core identity: name, mission, and personality.
  @[Chronicle::Packs::Annotations::ObjectType(name: "agent_profile")]
  struct AgentProfile
    include JSON::Serializable

    getter name : String
    getter mission : String = ""
    getter personality_description : String = ""
    getter owner_name : String? = nil
    getter version : String = "1"
    getter? active : Bool = true
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A standing goal the assistant is working toward.
  @[Chronicle::Packs::Annotations::ObjectType(name: "goal")]
  struct Goal
    include JSON::Serializable

    getter text : String
    getter priority : String = "medium"
    getter status : String = "active"
    getter domain : String? = nil
    getter profile_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A standing instruction scoped by channel and audience_role.
  @[Chronicle::Packs::Annotations::ObjectType(name: "standing_instruction")]
  struct StandingInstruction
    include JSON::Serializable

    getter text : String
    getter scope : String = "global"
    getter applies_to_channel : String? = nil
    getter applies_to_audience_role : String? = nil
    getter priority : Int32 = 50
    getter? active : Bool = true
    getter profile_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Fine-grained personality settings: tone, verbosity, formality.
  @[Chronicle::Packs::Annotations::ObjectType(name: "personality_profile")]
  struct PersonalityProfile
    include JSON::Serializable

    getter tone : String = "neutral"
    getter verbosity : String = "balanced"
    getter formality : String = "neutral"
    getter applies_to_channel : String? = nil
    getter applies_to_audience_role : String? = nil
    getter profile_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A named key/value preference set by the owner.
  @[Chronicle::Packs::Annotations::ObjectType(name: "owner_preference")]
  struct OwnerPreference
    include JSON::Serializable

    getter key : String
    getter value : String
    getter domain : String? = nil
    getter channel : String? = nil
    getter profile_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Request to assemble a scoped profile context view.
  @[Chronicle::Packs::Annotations::ObjectType(name: "profile_context_request")]
  struct ProfileContextRequest
    include JSON::Serializable

    getter profile_id : String
    getter channel : String? = nil
    getter audience_role : String? = nil
    getter? include_goals : Bool = true
    getter? include_preferences : Bool = true
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Assembled profile context for a specific channel/audience_role.
  @[Chronicle::Packs::Annotations::ObjectType(name: "profile_context_view")]
  struct ProfileContextView
    include JSON::Serializable

    getter profile_id : String
    getter channel : String?
    getter audience_role : String?
    getter agent_name : String
    getter mission : String
    getter personality : Hash(String, String)
    getter active_goals : Array(Hash(String, JSON::Any))
    getter standing_instructions : Array(String)
    getter owner_preferences : Hash(String, String)
    getter request_id : String?
    getter frame_id : String?
    getter metadata : Hash(String, JSON::Any)

    def initialize(
      @profile_id : String,
      @channel : String?,
      @audience_role : String?,
      @agent_name : String,
      @mission : String,
      @personality : Hash(String, String),
      @active_goals : Array(Hash(String, JSON::Any)),
      @standing_instructions : Array(String),
      @owner_preferences : Hash(String, String),
      @request_id : String?,
      @frame_id : String?,
      @metadata : Hash(String, JSON::Any),
    )
    end
  end
end

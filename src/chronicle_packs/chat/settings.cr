require "json"

module Chronicle::Packs::Chat
  # Settings for the Chat Adapter Pack. Ported from upstream
  # packs/chat/settings.py (ChatSettings). Controls LLM integration, context
  # assembly, and chat UX behaviors.
  struct ChatSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter llm_provider : String = "mock"
    getter model : String = "gpt-4o-mini"
    getter system_prompt_override : String? = nil
    getter reply_policy : String = "open"
    getter deflection_message : String = "Hi \u2014 I'm a personal assistant and I only chat with my owner and their approved contacts. Your message was received and logged."
    getter tool_allow_list : Array(String) = [] of String
    getter max_tool_turns : Int32 = 4
    getter max_context_messages : Int32 = 10
    getter? include_memory : Bool = true
    getter memory_write_path : String = "heuristic"
    getter memory_backend_url : String = ":memory:"
    getter memory_top_k : Int32 = 3
    getter memory_min_score : Float64 = 0.1
    getter? memory_subject_scoped : Bool = true
    getter? memory_include_global : Bool = false
    getter? include_profile : Bool = true
    getter? auto_approve_responses : Bool = true
    getter? typing_indicator_enabled : Bool = false

    def initialize(
      @llm_provider : String = "mock",
      @model : String = "gpt-4o-mini",
      @system_prompt_override : String? = nil,
      @reply_policy : String = "open",
      @deflection_message : String = "Hi \u2014 I'm a personal assistant and I only chat with my owner and their approved contacts. Your message was received and logged.",
      @tool_allow_list : Array(String) = [] of String,
      @max_tool_turns : Int32 = 4,
      @max_context_messages : Int32 = 10,
      @include_memory : Bool = true,
      @memory_write_path : String = "heuristic",
      @memory_backend_url : String = ":memory:",
      @memory_top_k : Int32 = 3,
      @memory_min_score : Float64 = 0.1,
      @memory_subject_scoped : Bool = true,
      @memory_include_global : Bool = false,
      @include_profile : Bool = true,
      @auto_approve_responses : Bool = true,
      @typing_indicator_enabled : Bool = false,
    )
    end
  end
end

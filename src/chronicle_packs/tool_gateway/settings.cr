require "json"

module Chronicle::Packs::ToolGateway
  # Configuration for Tool Gateway Pack v0.1. Ported from upstream
  # packs/tool_gateway/settings.py.
  struct ToolGatewaySettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter auto_approve_risk_classes : Array(String) = ["low"]
    getter capability_action_ceilings : Hash(String, String) = {} of String => String
    getter? record_input_data : Bool = true
    getter? record_output_data : Bool = true
    getter max_output_chars : Int32 = 10_000
    getter? create_source_from_result : Bool = true
    getter? sanitize_output : Bool = true
    getter approver_roles : Array(String) = ["owner", "admin"]
    getter? injection_scan : Bool = true
    getter? envelope_llm_output : Bool = true
    getter? inject_credentials : Bool = true

    def initialize(
      @auto_approve_risk_classes : Array(String) = ["low"],
      @capability_action_ceilings : Hash(String, String) = {} of String => String,
      @record_input_data : Bool = true,
      @record_output_data : Bool = true,
      @max_output_chars : Int32 = 10_000,
      @create_source_from_result : Bool = true,
      @sanitize_output : Bool = true,
      @approver_roles : Array(String) = ["owner", "admin"],
      @injection_scan : Bool = true,
      @envelope_llm_output : Bool = true,
      @inject_credentials : Bool = true,
    )
    end
  end
end

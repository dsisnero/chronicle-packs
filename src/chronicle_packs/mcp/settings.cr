require "json"

module Chronicle::Packs::MCP
  # Configuration for the MCP Pack (both directions). Ported from upstream
  # packs/mcp/settings.py (MCPSettings).

  struct MCPSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter servers : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter default_tool_risk : String = "high"
    getter default_tool_action_class : String = "R3"
    getter tokens : Hash(String, String) = {} of String => String
    getter expose_capabilities : Array(String) = [] of String
    getter memory_backend_url : String = ":memory:"
    getter default_exposures : Hash(String, Array(String)) = {
      "chat"          => ["owner"],
      "memory_search" => ["owner"],
      "tools"         => ["owner"],
      "catalog"       => ["owner"],
    }
    getter unverified_token_role : String = "owner"

    def initialize(
      @servers : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      @default_tool_risk : String = "high",
      @default_tool_action_class : String = "R3",
      @tokens : Hash(String, String) = {} of String => String,
      @expose_capabilities : Array(String) = [] of String,
      @memory_backend_url : String = ":memory:",
      @default_exposures : Hash(String, Array(String)) = {
        "chat"          => ["owner"],
        "memory_search" => ["owner"],
        "tools"         => ["owner"],
        "catalog"       => ["owner"],
      },
      @unverified_token_role : String = "owner",
    )
    end
  end
end

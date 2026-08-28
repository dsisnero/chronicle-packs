require "json"

module Chronicle::Packs::MCP
  # MCP Pack object types (bidirectional): an outbound server connection
  # record, an inbound exposure rule, and one inbound call audit record.
  # Ported from upstream packs/mcp/object_types.py.

  # Audit record of an outbound MCP server connection.
  @[Chronicle::Packs::Annotations::ObjectType(name: "mcp_server", description: "Connection/discovery record for an outbound MCP server.")]
  struct MCPServer
    include JSON::Serializable

    getter name : String
    getter direction : String = "outbound"
    getter server_info : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter tool_names : Array(String) = [] of String
    getter capability_keys : Array(String) = [] of String
    getter default_risk : String = "high"
    getter risk_overrides : Hash(String, String) = {} of String => String
    getter default_action_class : String = "R3"
    getter action_class_overrides : Hash(String, String) = {} of String => String
    getter status : String = "connected"
    getter error : String? = nil
    getter connected_at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @name : String,
      @direction : String = "outbound",
      @server_info : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @tool_names : Array(String) = [] of String,
      @capability_keys : Array(String) = [] of String,
      @default_risk : String = "high",
      @risk_overrides : Hash(String, String) = {} of String => String,
      @default_action_class : String = "R3",
      @action_class_overrides : Hash(String, String) = {} of String => String,
      @status : String = "connected",
      @error : String? = nil,
      @connected_at : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # An inbound exposure rule: surface → roles.
  @[Chronicle::Packs::Annotations::ObjectType(name: "mcp_exposure", description: "Inbound exposure rule: which surface is visible to which roles. Graph-native config — edited via the governed mcp.set_exposure capability.")]
  struct MCPExposure
    include JSON::Serializable

    getter surface : String
    getter roles : Array(String) = [] of String
    getter? enabled : Bool = true
    getter note : String = ""
    getter updated_at : String = ""
    getter updated_by : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @surface : String,
      @roles : Array(String) = [] of String,
      @enabled : Bool = true,
      @note : String = "",
      @updated_at : String = "",
      @updated_by : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Audit record of one inbound MCP call (who, what, allowed, why).
  @[Chronicle::Packs::Annotations::ObjectType(name: "mcp_access", description: "Audit record of one inbound MCP call (who, what, allowed, why).")]
  struct MCPAccess
    include JSON::Serializable

    getter method : String
    getter surface : String = ""
    getter caller : String = ""
    getter role : String? = nil
    getter? allowed : Bool = false
    getter reason : String = ""
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @method : String,
      @surface : String = "",
      @caller : String = "",
      @role : String? = nil,
      @allowed : Bool = false,
      @reason : String = "",
      @at : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

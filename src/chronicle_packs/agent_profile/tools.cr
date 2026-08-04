require "json"

module Chronicle::Packs::AgentProfile
  # Agent Profile tools. Ported from upstream packs/agent_profile/tools.py.
  # The `*_fn` functions take the graph explicitly; the declared
  # Chronicle::Tool wrappers read a graph bound by the host (chronicle's
  # Tool model is args-only).

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Add an AgentProfile to the graph and return the created object.
  def self.register_profile_fn(
    graph : Chronicle::GraphProjection,
    name : String,
    mission : String = "",
    personality_description : String = "",
    owner_name : String? = nil,
  ) : Chronicle::GraphObject
    data = JSON.build do |json|
      json.object do
        json.field "name", name
        json.field "mission", mission
        json.field "personality_description", personality_description
        json.field "owner_name", owner_name
        json.field "version", "1"
        json.field "active", true
        json.field "metadata", {} of String => JSON::Any
      end
    end
    graph.add_object("agent_profile", data)
  end

  # Create a ProfileContextRequest to trigger context assembly.
  def self.request_profile_context_fn(
    graph : Chronicle::GraphProjection,
    profile_id : String,
    channel : String? = nil,
    audience_role : String? = nil,
    frame_id : String? = nil,
    include_goals : Bool = true,
    include_preferences : Bool = true,
  ) : Chronicle::GraphObject
    data = JSON.build do |json|
      json.object do
        json.field "profile_id", profile_id
        json.field "channel", channel
        json.field "audience_role", audience_role
        json.field "include_goals", include_goals
        json.field "include_preferences", include_preferences
        json.field "frame_id", frame_id
        json.field "metadata", {} of String => JSON::Any
      end
    end
    graph.add_object("profile_context_request", data)
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "register_profile", description: "Register an AgentProfile in the graph. Triggers profile_registry_recorder to index it for context assembly. Returns the created profile object.", deterministic: true)]
  def register_profile_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = register_profile_fn(
      bound_graph_or_raise,
      input["name"]?.try(&.as_s?) || "",
      input["mission"]?.try(&.as_s?) || "",
      input["personality_description"]?.try(&.as_s?) || "",
      input["owner_name"]?.try(&.as_s?),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_profile_context", description: "Create a ProfileContextRequest to assemble a scoped context view. Triggers profile_context_provider behavior. Call run_until_idle after to read the ProfileContextView.", deterministic: true)]
  def request_profile_context_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = request_profile_context_fn(
      bound_graph_or_raise,
      input["profile_id"]?.try(&.as_s?) || "",
      input["channel"]?.try(&.as_s?),
      input["audience_role"]?.try(&.as_s?),
      input["frame_id"]?.try(&.as_s?),
      input["include_goals"]?.try(&.as_bool?) != false,
      input["include_preferences"]?.try(&.as_bool?) != false,
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "agent_profile tools require a bound graph (set AgentProfile.bound_graph)"
    )
  end
end

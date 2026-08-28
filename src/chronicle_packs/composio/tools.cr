require "json"

module Chronicle::Packs::Composio
  # Graph-visible proposals for Composio route operations. Ported from
  # upstream packs/composio/tools.py. The `*_fn` functions are the ported
  # behavior and take the graph explicitly. The declared Chronicle::Tool
  # wrappers read a graph bound by the host via `bound_graph`.

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Propose a capability_call through the Tool Gateway.
  def self._propose(
    graph : Chronicle::GraphProjection,
    capability : String,
    action_class : String,
    risk_class : String,
    input_data : Hash(String, JSON::Any),
    proposed_by : String,
  ) : Chronicle::GraphObject
    graph.add_object("capability_call", ToolGateway::CapabilityCall.new(
      provider_id: "",
      provider_name: "composio",
      capability_name: capability,
      input_data: input_data,
      credential_ref_name: nil,
      credential_ref_id: nil,
      risk_class: ToolGateway::RiskClass.parse?(risk_class) || ToolGateway::RiskClass::Low,
      action_class: action_class,
      status: ToolGateway::CallStatus::Proposed,
      proposed_by: proposed_by,
      frame_id: nil,
      proposed_at: nil,
      metadata: {"route" => JSON::Any.new("composio")},
    ).to_json, actor: "composio")
  end

  # Propose an owner-approved Connect Link for one service (R4, high risk).
  def self.request_composio_link_fn(
    graph : Chronicle::GraphProjection,
    user_id : String,
    service : String,
    callback_url : String,
  ) : Chronicle::GraphObject
    _propose(
      graph, "connections.link", "R4", "high",
      {"user_id" => JSON::Any.new(user_id), "service" => JSON::Any.new(service), "callback_url" => JSON::Any.new(callback_url)},
      "composio.connection_ladder",
    )
  end

  # Propose a read-only status check for one service (R0, low risk).
  def self.request_composio_status_fn(
    graph : Chronicle::GraphProjection,
    user_id : String,
    service : String,
    limit : Int32 = 25,
  ) : Chronicle::GraphObject
    _propose(
      graph, "connections.status", "R0", "low",
      {"user_id" => JSON::Any.new(user_id), "service" => JSON::Any.new(service), "limit" => JSON::Any.new(limit)},
      "composio.connection_ladder",
    )
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "composio tools require a bound graph (set Composio.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "request_composio_link", description: "Propose an owner-approved Connect Link for one service.", deterministic: true)]
  def request_composio_link_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = request_composio_link_fn(
      bound_graph_or_raise,
      user_id: input["user_id"]?.try(&.as_s?) || "",
      service: input["service"]?.try(&.as_s?) || "",
      callback_url: input["callback_url"]?.try(&.as_s?) || "",
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_composio_status", description: "Propose a read-only status check for one service.", deterministic: true)]
  def request_composio_status_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = request_composio_status_fn(
      bound_graph_or_raise,
      user_id: input["user_id"]?.try(&.as_s?) || "",
      service: input["service"]?.try(&.as_s?) || "",
      limit: input["limit"]?.try(&.as_i?) || 25,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end
end

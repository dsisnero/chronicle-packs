require "json"
require "time"

module Chronicle::Packs::Communication
  # Communication tools. Ported from upstream packs/communication/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Create a channel-neutral CommMessage directly.
  def self.create_comm_message_fn(
    graph : Chronicle::GraphProjection,
    channel : String,
    content : String,
    sender_ref : String = "",
    direction : String = "inbound",
    thread_id : String? = nil,
    intent_hint : String? = nil,
    frame_id : String? = nil,
    source_id : String? = nil,
    metadata : Hash(String, JSON::Any)? = nil,
  ) : Chronicle::GraphObject
    message = CommMessage.new(
      channel: channel,
      sender_ref: sender_ref,
      content: content,
      direction: MessageDirection.parse?(direction) || MessageDirection::Inbound,
      thread_id: thread_id,
      intent_hint: intent_hint,
      source_id: source_id,
      created_at: _now_iso,
      frame_id: frame_id,
      metadata: metadata || {} of String => JSON::Any,
    )
    graph.add_object("comm_message", message.to_json, actor: "communication")
  end

  # Create a CommResponseCandidate for a message.
  def self.create_response_candidate_fn(
    graph : Chronicle::GraphProjection,
    message_id : String,
    channel : String = "",
    content : String = "",
    thread_id : String? = nil,
    status : String = "proposed",
    artifact_id : String? = nil,
    created_by_behavior : String = "manual",
    frame_id : String? = nil,
  ) : Chronicle::GraphObject
    candidate = CommResponseCandidate.new(
      message_id: message_id,
      thread_id: thread_id,
      channel: channel,
      content: content,
      artifact_id: artifact_id,
      status: ResponseStatus.parse?(status) || ResponseStatus::Proposed,
      created_by_behavior: created_by_behavior,
      frame_id: frame_id,
    )
    graph.add_object("comm_response_candidate", candidate.to_json, actor: "communication")
  end

  # Approve a CommResponseCandidate, triggering response_dispatcher.
  def self.approve_response_fn(graph : Chronicle::GraphProjection, candidate_id : String) : Chronicle::GraphObject
    obj = graph.get_object(candidate_id)
    raise Chronicle::Packs::PackError.new("unknown comm_response_candidate #{candidate_id}") if obj.nil?
    data = JSON.parse(obj.data).as_h
    data["status"] = JSON::Any.new("approved")
    graph.patch_object(candidate_id, data.to_json)
    graph.get_object(candidate_id) || raise Chronicle::Packs::PackError.new("comm_response_candidate #{candidate_id} not projected")
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "create_comm_message", description: "Create a channel-neutral CommMessage directly (bypassing channel adapters). Creates a comm_message object.", deterministic: true)]
  def create_comm_message_tool(args : String) : String
    input = JSON.parse(args).as_h
    metadata = (input["metadata"]?.try(&.as_h) || {} of String => JSON::Any)
    result = create_comm_message_fn(
      bound_graph_or_raise,
      input["channel"]?.try(&.as_s?) || "",
      input["content"]?.try(&.as_s?) || "",
      input["sender_ref"]?.try(&.as_s?) || "",
      input["direction"]?.try(&.as_s?) || "inbound",
      input["thread_id"]?.try(&.as_s?),
      input["intent_hint"]?.try(&.as_s?),
      input["frame_id"]?.try(&.as_s?),
      metadata: metadata,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_response_candidate", description: "Create a CommResponseCandidate for a message.", deterministic: true)]
  def create_response_candidate_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = create_response_candidate_fn(
      bound_graph_or_raise,
      input["message_id"]?.try(&.as_s?) || "",
      input["channel"]?.try(&.as_s?) || "",
      input["content"]?.try(&.as_s?) || "",
      input["thread_id"]?.try(&.as_s?),
      input["status"]?.try(&.as_s?) || "proposed",
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "approve_response", description: "Approve a CommResponseCandidate, triggering response_dispatcher.", deterministic: true)]
  def approve_response_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = approve_response_fn(bound_graph_or_raise, input["candidate_id"]?.try(&.as_s?) || "")
    {"id" => result.id, "status" => JSON.parse(result.data)["status"]?}.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "communication tools require a bound graph (set Communication.bound_graph)"
    )
  end
end

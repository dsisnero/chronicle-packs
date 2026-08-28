require "json"

module Chronicle::Packs::Chat
  # Chat tools. Ported from upstream packs/chat/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Submit a chat message from a user. Returns the ChatInput object.
  def self.submit_chat_input_fn(
    graph : Chronicle::GraphProjection,
    user_ref : String,
    content : String,
    session_id : String? = nil,
    frame_id : String? = nil,
    metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
  ) : Chronicle::GraphObject
    graph.add_object("chat_input", ChatInput.new(
      user_ref: user_ref,
      content: content,
      session_id: session_id,
      frame_id: frame_id,
      role: "user",
      metadata: metadata,
    ).to_json, actor: "chat")
  end

  # Return all ChatTurn objects for a session, ordered by turn_number.
  def self.get_session_turns_fn(graph : Chronicle::GraphProjection, session_id : String) : Array(Chronicle::GraphObject)
    turns = graph.objects(type: "chat_turn").select do |obj|
      JSON.parse(obj.data)["session_id"]?.try(&.as_s?) == session_id
    end
    turns.sort_by! { |turn| JSON.parse(turn.data)["turn_number"]?.try(&.as_i?) || 0 }
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "chat tools require a bound graph (set Chat.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "submit_chat_input", description: "Submit a chat message from a user. Creates ChatInput → chat_ingester → CommMessage + ChatSession + ChatTurn → chat_llm_responder → CommResponseCandidate → chat_responder delivers response.", deterministic: true)]
  def submit_chat_input_tool(args : String) : String
    input = JSON.parse(args).as_h
    metadata = (input["metadata"]?.try(&.as_h) || {} of String => JSON::Any)
    result = submit_chat_input_fn(
      bound_graph_or_raise,
      input["user_ref"]?.try(&.as_s?) || "",
      input["content"]?.try(&.as_s?) || "",
      input["session_id"]?.try(&.as_s?),
      input["frame_id"]?.try(&.as_s?),
      metadata: metadata,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_session_turns", description: "Return all ChatTurn objects for a given session_id (ordered by turn_number).", deterministic: true)]
  def get_session_turns_tool(args : String) : String
    input = JSON.parse(args).as_h
    turns = get_session_turns_fn(bound_graph_or_raise, input["session_id"]?.try(&.as_s?) || "")
    turns.map { |turn| JSON.parse(turn.data) }.to_json
  end
end

require "json"

module Chronicle::Packs::MemoryGateway
  # Memory Gateway tools. Ported from upstream packs/memory_gateway/tools.py
  # (slice 1: retrieve_memories). resolve_memory_query (the procedure
  # resolver) is deferred.

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Query the memory backend and return ranked results.
  def self.retrieve_memories_fn(graph : Chronicle::GraphProjection, query : String, top_k : Int32 = 10, min_score : Float64 = 0.2, category : String? = nil, behavior_name : String? = nil, frame_id : String? = nil, subject_ref : String? = nil, subject_scoped : Bool = false, include_global : Bool = true, exclude_frame_id : String? = nil) : Array(Hash(String, JSON::Any))
    results = Backend.retrieve_by_query(
      graph, query,
      top_k: top_k, min_score: min_score, category: category,
      subject_ref: subject_ref, subject_scoped: subject_scoped,
      include_global: include_global, exclude_frame_id: exclude_frame_id,
    )
    results.each { |result| Backend.update_retrieval(graph, result["item_id"].as_s) }
    results
  end

  @[Chronicle::Packs::Annotations::Tool(name: "retrieve_memories", description: "Retrieve relevant MemoryItems for a query with outcome-adjusted relevance plus raw relevance and reliability.", deterministic: true)]
  def retrieve_memories_tool(args : String) : String
    input = JSON.parse(args).as_h
    results = retrieve_memories_fn(
      bound_graph_or_raise,
      input["query"]?.try(&.as_s?) || "",
      top_k: input["top_k"]?.try(&.as_i?) || 10,
      min_score: input["min_score"]?.try(&.as_f?) || 0.2,
      category: input["category"]?.try(&.as_s?),
      behavior_name: input["behavior_name"]?.try(&.as_s?),
      frame_id: input["frame_id"]?.try(&.as_s?),
      subject_ref: input["subject_ref"]?.try(&.as_s?),
      subject_scoped: input["subject_scoped"]?.try(&.as_bool?) || false,
      include_global: input["include_global"]?.try(&.as_bool?) || true,
    )
    JSON::Any.new(results.map { |row| JSON::Any.new(row) }).to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "memory_gateway tools require a bound graph (set MemoryGateway.bound_graph)"
    )
  end
end

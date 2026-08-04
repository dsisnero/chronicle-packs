require "json"

module Chronicle::Packs::Entity
  # Entity tools. Ported from upstream packs/entity/tools.py. The `*_fn`
  # functions take the graph explicitly; the declared Chronicle::Tool
  # wrappers read a graph bound by the host (chronicle's Tool model is
  # args-only).

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Add an Entity to the graph and return the created object.
  def self.register_entity_fn(
    graph : Chronicle::GraphProjection,
    name : String,
    entity_type : String = "other",
    aliases : Array(String) = [] of String,
    identifiers : Hash(String, String) = {} of String => String,
    description : String = "",
    confidence : Float64 = 0.9,
  ) : Chronicle::GraphObject
    data = JSON.build do |json|
      json.object do
        json.field "name", name
        json.field "entity_type", entity_type
        json.field "aliases", aliases
        json.field "identifiers", identifiers.to_h { |k, v| {k, JSON::Any.new(v)} }
        json.field "confidence", confidence
        json.field "description", description
        json.field "source_ids", [] of String
        json.field "merged_from_ids", [] of String
        json.field "metadata", {} of String => JSON::Any
      end
    end
    graph.add_object("entity", data)
  end

  # Create a MergeDecision for a MergeCandidate; accepted merges create a
  # merged_into relation from the other entity.
  def self.decide_merge_fn(
    graph : Chronicle::GraphProjection,
    merge_candidate_id : String,
    decision : String,
    surviving_entity_id : String? = nil,
    rationale : String = "",
    decided_by : String? = nil,
  ) : Chronicle::GraphObject
    decision_obj = graph.add_object("merge_decision", JSON.build do |json|
      json.object do
        json.field "merge_candidate_id", merge_candidate_id
        json.field "decision", decision
        json.field "surviving_entity_id", surviving_entity_id
        json.field "rationale", rationale
        json.field "decided_by", decided_by || "operator"
        json.field "metadata", {} of String => JSON::Any
      end
    end)

    begin
      if candidate = graph.get_object(merge_candidate_id)
        merged = JSON.parse(candidate.data).as_h
        merged["status"] = JSON::Any.new(decision)
        graph.patch_object(merge_candidate_id, merged.to_json)
      end
    rescue
    end

    if decision == "accepted" && surviving_entity_id
      begin
        if candidate = graph.get_object(merge_candidate_id)
          data = JSON.parse(candidate.data).as_h
          a_id = data["entity_a_id"]?.try(&.as_s?)
          b_id = data["entity_b_id"]?.try(&.as_s?)
          other_id = a_id == surviving_entity_id ? b_id : a_id
          graph.add_relation(other_id, surviving_entity_id, "merged_into") if other_id
        end
      rescue
      end
    end

    decision_obj
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "register_entity", description: "Register a canonical Entity in the graph. Triggers entity_registry_recorder (local index) and merge_candidate_detector (dedup check). Returns the created entity object.", deterministic: true)]
  def register_entity_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = register_entity_fn(
      bound_graph_or_raise,
      input["name"]?.try(&.as_s?) || "",
      input["entity_type"]?.try(&.as_s?) || "other",
      input["aliases"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      (input["identifiers"]?.try(&.as_h) || {} of String => JSON::Any).to_h { |k, v| {k, v.as_s} },
      input["description"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "decide_merge", description: "Create a MergeDecision for a MergeCandidate. Use decision='accepted' to merge, 'rejected' to keep separate, 'deferred' to revisit later.", deterministic: true)]
  def decide_merge_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = decide_merge_fn(
      bound_graph_or_raise,
      input["merge_candidate_id"]?.try(&.as_s?) || "",
      input["decision"]?.try(&.as_s?) || "",
      input["surviving_entity_id"]?.try(&.as_s?),
      input["rationale"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "entity tools require a bound graph (set Entity.bound_graph)"
    )
  end
end

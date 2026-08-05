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

  # Subject allows evidence: subject_ref match or owner-profile scope.
  def self._subject_allows_evidence(data : Hash(String, JSON::Any), subject_ref : String?) : Bool
    return true if subject_ref.nil?

    metadata = data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
    explicit = metadata["subject_ref"]?.try(&.as_s?)
    if explicit
      return explicit == subject_ref
    end
    subject_ref == "owner" && metadata["subject_scope"]?.try(&.as_s?) == "owner_profile"
  end

  # Resolve over registered procedures with raw evidence as the floor.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream resolver
  def self.resolve_memory_query_fn(graph : Chronicle::GraphProjection, query : String, subject_ref : String? = nil, top_k : Int32 = 8, min_score : Float64 = 0.2, source_domain : String = "general", query_scope : String = "general") : Hash(String, JSON::Any)
    evidence_rows = [] of {Float64, Float64, Chronicle::GraphObject, Hash(String, JSON::Any)}
    graph.objects(type: "activity_evidence").each do |obj|
      data = JSON.parse(obj.data).as_h
      next unless data["status"]?.try(&.as_s?) == "current"
      next unless _subject_allows_evidence(data, subject_ref)

      raw_score = Backend.lexical_score(query, data["normalized_content"]?.try(&.as_s?) || "")
      next if raw_score < min_score

      trust = Attention.get_source_trust_fn(graph, data["source_surface_id"]?.try(&.as_s?) || data["source_ref"]?.try(&.as_s?) || "unknown", domain: source_domain, query_scope: query_scope)
      multiplier = 0.5 + ((trust["score_milli"]?.try(&.as_i) || 500).to_f64 / 1_000)
      evidence_rows << {raw_score * multiplier, raw_score, obj, trust}
    end
    evidence_rows.sort_by! { |weighted, raw, _obj, _trust| {-weighted, -raw} }
    evidence_rows = evidence_rows[0, top_k]
    evidence_ids = evidence_rows.map { |_weighted, _raw, obj, _trust| obj.id }

    annotation_rows = [] of {Float64, Chronicle::GraphObject, String}
    if !evidence_ids.empty?
      graph.objects(type: "semantic_annotation").each do |obj|
        data = JSON.parse(obj.data).as_h
        next unless data["status"]?.try(&.as_s?) == "active"
        next unless evidence_ids.includes?(data["evidence_id"]?.try(&.as_s?) || "")

        body = data["body"]?.try(&.as_h) || {} of String => JSON::Any
        text = body["text"]?.try(&.as_s?) || body["tag"]?.try(&.as_s?) || ""
        score = Backend.lexical_score(query, text)
        next if text.empty? || score < min_score

        annotation_rows << {score, obj, text}
      end
      annotation_rows.sort_by! { |score, obj, _text| {-score, obj.id} }
      annotation_rows = annotation_rows[0, top_k]
    end

    memory_rows = retrieve_memories_fn(graph, query, top_k: top_k, min_score: min_score, subject_ref: subject_ref, subject_scoped: !subject_ref.nil?, include_global: subject_ref.nil?)

    blocks = [] of String
    if !evidence_rows.empty?
      blocks << "[authoritative-evidence]"
      evidence_rows.each do |_weighted, _raw, obj, trust|
        data = JSON.parse(obj.data).as_h
        blocks << "- evidence_id=#{obj.id} | source=#{data["source_ref"]?.try(&.as_s?) || ""} | trust=#{trust["verdict"]?.try(&.as_s?) || "unproven"}:#{trust["score_milli"]?.try(&.as_i) || 500} | #{data["normalized_content"]?.try(&.as_s?) || ""}"
      end
    end
    if !annotation_rows.empty?
      blocks << "[evidence-annotations]"
      annotation_rows.each do |_score, obj, text|
        data = JSON.parse(obj.data).as_h
        blocks << "- annotation_id=#{obj.id} | evidence_id=#{data["evidence_id"]?.try(&.as_s?) || ""} | #{text}"
      end
    end
    if !memory_rows.empty?
      blocks << "[admitted-memory-augmentation]"
      memory_rows.each do |row|
        blocks << "- memory_item_id=#{row["item_id"]?.try(&.as_s?) || ""} | #{row["text"]?.try(&.as_s?) || ""}"
      end
    end

    selected_tier, procedure_id = if !annotation_rows.empty?
                                    {"annotated_evidence", "memory.annotated_evidence@0.1.0"}
                                  elsif !evidence_rows.empty?
                                    {"evidence", "memory.raw_evidence@0.1.0"}
                                  elsif !memory_rows.empty?
                                    {"compiled_belief", "memory.admitted_items@0.1.0"}
                                  else
                                    {"none", "memory.no_match@0.1.0"}
                                  end
    confidence_values = [] of Float64
    evidence_rows.each { |score, _raw, _obj, _trust| confidence_values << Math.min(score, 1.0) }
    annotation_rows.each { |score, _obj, _text| confidence_values << score }
    memory_rows.each { |row| confidence_values << (row["score"]?.try(&.as_f?) || 0.0) }
    confidence = confidence_values.max? || 0.0

    tier_enum = ResolutionTier.parse?(selected_tier) || ResolutionTier::None
    resolution = MemoryQueryResolution.new(
      query, subject_ref, tier_enum, procedure_id,
      evidence_ids: evidence_ids,
      annotation_ids: annotation_rows.map { |_score, obj, _text| obj.id },
      memory_item_ids: memory_rows.map { |row| row["item_id"]?.try(&.as_s?) || "" },
      context_text: blocks.join("
"), confidence: Math.min(confidence, 1.0),
      authoritative_evidence: true,
      coverage: {"procedures_checked" => JSON::Any.new(["raw_evidence", "annotated_evidence", "admitted_items", "live_lookup"].map { |procedure| JSON::Any.new(procedure) }), "live_lookup_available" => JSON::Any.new(false)},
      metadata: {"rule" => JSON::Any.new("evidence_precedes_derived_artifacts")},
    )
    resolution_obj = graph.add_object("memory_query_resolution", resolution.to_json)
    {"resolution_id" => JSON::Any.new(resolution_obj.id), "query" => JSON::Any.new(query), "subject_ref" => subject_ref ? JSON::Any.new(subject_ref) : JSON::Any.new(nil), "selected_tier" => JSON::Any.new(selected_tier), "procedure_id" => JSON::Any.new(procedure_id), "evidence_ids" => JSON::Any.new(evidence_ids.map { |id| JSON::Any.new(id) }), "annotation_ids" => JSON::Any.new(annotation_rows.map { |_s, obj, _t| JSON::Any.new(obj.id) }), "memory_item_ids" => JSON::Any.new(memory_rows.map { |row| JSON::Any.new(row["item_id"]?.try(&.as_s?) || "") }), "context_text" => JSON::Any.new(blocks.join("\n")), "confidence" => JSON::Any.new(Math.min(confidence, 1.0)), "authoritative_evidence" => JSON::Any.new(true)}
  end

  @[Chronicle::Packs::Annotations::Tool(name: "resolve_memory_query", description: "Resolve a memory query through raw evidence, annotations, admitted items, and the reserved live-lookup slot; evidence is authoritative.", deterministic: true)]
  def resolve_memory_query_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = resolve_memory_query_fn(
      bound_graph_or_raise,
      input["query"]?.try(&.as_s?) || "",
      subject_ref: input["subject_ref"]?.try(&.as_s?),
      top_k: input["top_k"]?.try(&.as_i?) || 8,
      min_score: input["min_score"]?.try(&.as_f?) || 0.2,
      source_domain: input["source_domain"]?.try(&.as_s?) || "general",
      query_scope: input["query_scope"]?.try(&.as_s?) || "general",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "memory_gateway tools require a bound graph (set MemoryGateway.bound_graph)"
    )
  end
end

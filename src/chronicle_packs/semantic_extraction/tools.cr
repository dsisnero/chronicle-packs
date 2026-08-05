require "json"

module Chronicle::Packs::SemanticExtraction
  # Semantic Extraction tools. Ported from upstream
  # packs/semantic_extraction/tools.py (slice 1: extract_annotations,
  # annotation_coverage). Profile updates, extractor trials, LLM promotion,
  # and procedure synthesis are deferred.

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Extract annotations from one evidence revision through the profile policy.
  def self.extract_annotations_fn(graph : Chronicle::GraphProjection, evidence_id : String, settings : SemanticExtractionSettings, requested_facets : Array(String)? = nil) : Hash(String, JSON::Any)
    evidence_obj = graph.get_object(evidence_id)
    raise Chronicle::Packs::PackError.new("unknown activity_evidence: #{evidence_id}") if evidence_obj.nil? || evidence_obj.type != "activity_evidence"

    results = run_profile_extraction(graph, evidence_obj, settings: settings, requested_facets: requested_facets)
    last = results.last?
    return {"ok" => JSON::Any.new(false)} if last.nil?

    last
  end

  # Read the coverage record for one extraction run.
  def self.annotation_coverage_fn(graph : Chronicle::GraphProjection, run_id : String) : JSON::Any?
    coverage = graph.objects(type: "extraction_coverage").find { |obj| JSON.parse(obj.data)["run_id"]?.try(&.as_s?) == run_id }
    coverage ? JSON.parse(coverage.data) : nil
  end

  @[Chronicle::Packs::Annotations::Tool(name: "extract_annotations", description: "Extract typed annotations from an evidence revision through the active extraction profile.", deterministic: true)]
  def extract_annotations_tool(args : String) : String
    input = JSON.parse(args).as_h
    settings = input["settings"]? ? SemanticExtractionSettings.from_json(input["settings"].to_json) : SemanticExtractionSettings.new
    requested = input["requested_facets"]?.try(&.as_a?.try(&.map(&.as_s)))
    result = extract_annotations_fn(bound_graph_or_raise, input["evidence_id"]?.try(&.as_s?) || "", settings, requested_facets: requested)
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "annotation_coverage", description: "Read the extraction coverage record for an extraction run.", deterministic: true)]
  def annotation_coverage_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = annotation_coverage_fn(bound_graph_or_raise, input["run_id"]?.try(&.as_s?) || "")
    result ? result.to_json : "null"
  end

  # Mint the next extraction_profile version; supersede the active one.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream profile versioner
  def self.update_extraction_profile_fn(graph : Chronicle::GraphProjection, default_facets : Array(String)? = nil, facets_by_source_category : Hash(String, Array(String))? = nil, extractor_by_facet : Hash(String, String)? = nil, rationale : String = "", created_by : String = "owner") : Hash(String, JSON::Any)
    (default_facets || [] of String).each { |facet| _validate_facet_ref(facet, nil) }
    (facets_by_source_category || {} of String => Array(String)).values.flatten.each { |facet| _validate_facet_ref(facet, nil) }
    (extractor_by_facet || {} of String => String).each do |facet, ref|
      _validate_facet_ref(facet, ref)
    end

    profiles = graph.objects(type: "extraction_profile").sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }
    current = profiles.reverse.find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    version = profiles.empty? ? 1 : ((JSON.parse(profiles.last.data)["version"]?.try(&.as_i) || 0) + 1)
    base = current ? JSON.parse(current.data).as_h : {} of String => JSON::Any
    new_profile = ExtractionProfile.new(
      stable_id("extraction_profile", version), version,
      (default_facets || (base["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String)).sort,
      created_by,
      facets_by_source_category: facets_by_source_category ? facets_by_source_category.transform_values(&.sort) : (base["facets_by_source_category"]?.try(&.as_h) || {} of String => JSON::Any).transform_values { |v| v.as_a.map(&.as_s) },
      extractor_by_facet: extractor_by_facet ? extractor_by_facet : (base["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any).transform_values(&.as_s),
      rationale: rationale, supersedes_profile_id: current ? current.id : nil,
    )
    profile_obj = graph.add_object("extraction_profile", new_profile.to_json)
    if current
      old = JSON.parse(current.data).as_h
      old["status"] = JSON::Any.new("superseded")
      graph.patch_object(current.id, JSON::Any.new(old).to_json)
    end
    {"ok" => JSON::Any.new(true), "profile_id" => JSON::Any.new(profile_obj.id), "version" => JSON::Any.new(version)}
  end

  def self._validate_facet_ref(facet : String, ref : String?) : Nil
    standard = Facet.parse?(facet) != nil
    raise Chronicle::Packs::PackError.new("unknown facet #{facet.inspect}") unless standard || facet.includes?(".")
    if ref
      parts = ref.split("@")
      if parts.size != 2 || parts[0].empty? || parts[1].empty?
        raise Chronicle::Packs::PackError.new("malformed extractor reference #{ref.inspect}")
      end
    end
  end

  # Disable an extractor version and everything that depends on it.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream invalidation walk
  def self.invalidate_annotation_extractor_fn(graph : Chronicle::GraphProjection, extractor_id : String, extractor_version : String, reason : String) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("an invalidation reason is required") if reason.empty?

    graph.add_object("annotation_extractor_state", JSON.build do |json|
      json.object do
        json.field "state_identity", stable_id("annotation_extractor_state", extractor_id, extractor_version, reason)
        json.field "extractor_id", extractor_id
        json.field "extractor_version", extractor_version
        json.field "status", "disabled"
        json.field "reason", reason
      end
    end)

    invalidated_runs = 0
    graph.objects(type: "extraction_run").each do |run|
      data = JSON.parse(run.data).as_h
      if data["extractor_id"]?.try(&.as_s?) == extractor_id && data["extractor_version"]?.try(&.as_s?) == extractor_version && data["status"]?.try(&.as_s?) == "completed"
        old = JSON.parse(run.data).as_h
        old["status"] = JSON::Any.new("invalidated")
        graph.patch_object(run.id, JSON::Any.new(old).to_json)
        invalidated_runs += 1
      end
    end

    invalidated_annotations = 0
    graph.objects(type: "semantic_annotation").each do |annotation_obj|
      data = JSON.parse(annotation_obj.data).as_h
      if data["extractor_id"]?.try(&.as_s?) == extractor_id && data["extractor_version"]?.try(&.as_s?) == extractor_version && data["status"]?.try(&.as_s?) == "active"
        old = JSON.parse(annotation_obj.data).as_h
        old["status"] = JSON::Any.new("invalidated")
        old["invalidation_reason"] = JSON::Any.new(reason)
        graph.patch_object(annotation_obj.id, JSON::Any.new(old).to_json)
        invalidated_annotations += 1
      end
    end

    invalidated_candidates = 0
    ["profile_candidate", "memory_candidate"].each do |candidate_type|
      graph.objects(type: candidate_type).each do |candidate|
        data = JSON.parse(candidate.data).as_h
        metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
        next unless metadata["annotation_identity"]?.try(&.as_s?)
        annotation_object = graph.objects(type: "semantic_annotation").find { |obj| JSON.parse(obj.data)["annotation_identity"]?.try(&.as_s?) == metadata["annotation_identity"].as_s }
        next if annotation_object.nil?

        annotation_data = JSON.parse(annotation_object.data).as_h
        next unless annotation_data["extractor_id"]?.try(&.as_s?) == extractor_id && annotation_data["extractor_version"]?.try(&.as_s?) == extractor_version
        next unless annotation_data["status"]?.try(&.as_s?) == "invalidated"

        old = JSON.parse(candidate.data).as_h
        if candidate_type == "profile_candidate"
          old["status"] = JSON::Any.new("invalidated")
        else
          old["accepted"] = JSON::Any.new(false)
        end
        graph.patch_object(candidate.id, JSON::Any.new(old).to_json)
        invalidated_candidates += 1
      end
    end

    {"ok" => JSON::Any.new(true), "invalidated_runs" => JSON::Any.new(invalidated_runs), "invalidated_annotations" => JSON::Any.new(invalidated_annotations), "invalidated_candidates" => JSON::Any.new(invalidated_candidates)}
  end

  @[Chronicle::Packs::Annotations::Tool(name: "update_extraction_profile", description: "Mint the next extraction_profile version, superseding the active one.", deterministic: true)]
  def update_extraction_profile_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = update_extraction_profile_fn(
      bound_graph_or_raise,
      default_facets: input["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))),
      facets_by_source_category: input["facets_by_source_category"]?.try(&.as_h) ? input["facets_by_source_category"].as_h.transform_values { |v| v.as_a.map(&.as_s) } : nil,
      extractor_by_facet: input["extractor_by_facet"]?.try(&.as_h) ? input["extractor_by_facet"].as_h.transform_values(&.as_s) : nil,
      rationale: input["rationale"]?.try(&.as_s?) || "",
      created_by: input["created_by"]?.try(&.as_s?) || "owner",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "invalidate_annotation_extractor", description: "Disable an extractor version and invalidate its runs, annotations, and dependent candidates.", deterministic: true)]
  def invalidate_annotation_extractor_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = invalidate_annotation_extractor_fn(
      bound_graph_or_raise,
      input["extractor_id"]?.try(&.as_s?) || "", input["extractor_version"]?.try(&.as_s?) || "",
      reason: input["reason"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "semantic_extraction tools require a bound graph (set SemanticExtraction.bound_graph)"
    )
  end
end

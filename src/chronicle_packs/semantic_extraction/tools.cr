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

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "semantic_extraction tools require a bound graph (set SemanticExtraction.bound_graph)"
    )
  end
end

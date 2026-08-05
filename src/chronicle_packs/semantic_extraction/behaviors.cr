require "json"

module Chronicle::Packs::SemanticExtraction
  # Semantic Extraction behaviors. Ported from upstream
  # packs/semantic_extraction/behaviors.py (slice 1: seed_extraction_profile,
  # annotate_evidence). The selection/projection behaviors and the procedure
  # pipeline are deferred.

  # Seed extraction_profile v1 on pack load if none exists.
  @[Chronicle::Packs::Annotations::Behavior(name: "seed_extraction_profile", on: ["pack.loaded"], where: {"name" => "semantic_extraction"}, creates: ["extraction_profile"])]
  def seed_extraction_profile(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SemanticExtractionSettings) : Nil
    return if !settings.seed_default_profile?

    existing = graph.objects(type: "extraction_profile").any? { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    return if existing

    profile = ExtractionProfile.new(
      stable_id("extraction_profile", 1), 1, settings.default_profile_facets.sort, "semantic_extraction.seed",
      facets_by_source_category: settings.default_facets_by_source_category.transform_values(&.sort),
      rationale: "D041: seeded eager facet floor; owner-editable policy artifact (D042)",
    )
    graph.add_object("extraction_profile", profile.to_json)
  end

  # Run the profile's extractor policy eagerly over each new evidence revision.
  @[Chronicle::Packs::Annotations::Behavior(name: "annotate_evidence", on: ["object.created"], where: {"type" => "activity_evidence"}, creates: ["semantic_annotation", "extraction_run", "extraction_coverage"])]
  def annotate_evidence(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SemanticExtractionSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload).as_h
    evidence_id = payload["id"]?.try(&.as_s?)
    return if evidence_id.nil?

    evidence_obj = graph.get_object(evidence_id)
    return if evidence_obj.nil? || JSON.parse(evidence_obj.data)["status"]?.try(&.as_s?) != "current"

    metadata = JSON.parse(evidence_obj.data)["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
    return if metadata["interpretation_family"]?.try(&.as_s?)

    run_profile_extraction(graph, evidence_obj, settings: settings)
  end
end

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

  # Domain policy: which annotations merit a profile candidate. Everything
  # stays a candidate — promotion is a verdict or a governed gate, never
  # this projector.
  @[Chronicle::Packs::Annotations::Behavior(name: "project_profile_candidates", on: ["object.created"], where: {"type" => "semantic_annotation", "data.metadata.profile_candidate_eligible" => true}, creates: ["profile_candidate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream profile projector
  def project_profile_candidates(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SemanticExtractionSettings) : Nil
    return if !settings.enabled? || !settings.mint_profile_candidates?

    payload = JSON.parse(event.payload).as_h
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "active"

    evidence_id = data["evidence_id"]?.try(&.as_s?)
    evidence = evidence_id ? graph.get_object(evidence_id) : nil
    return if evidence.nil?

    metadata = JSON.parse(evidence.data)["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
    return unless metadata["subject_scope"]?.try(&.as_s?) == "owner_profile"

    facet = data["facet"]?.try(&.as_s?)
    body = data["body"]?.try(&.as_h) || {} of String => JSON::Any
    attribution = data["attribution"]?.try(&.as_s?)
    attribute : String? = nil
    value : String? = nil
    if facet == "entity_mention" && body["kind"]?.try(&.as_s?).in?({"handle", "email", "url"})
      attribute = body["kind"]?.try(&.as_s?)
      value = body["normalized"]?.try(&.as_s?) || body["text"]?.try(&.as_s?)
    elsif facet == "assertion" && attribution.in?({"subject_self", "author_about_subject"})
      attribute = "profile_statement"
      value = body["text"]?.try(&.as_s?)
    elsif facet == "preference_expression"
      attribute = "preference"
      value = body["text"]?.try(&.as_s?)
    end
    return if attribute.nil? || value.nil? || value.empty?

    candidate_identity = stable_id("candidate", "profile", data["annotation_identity"]?.try(&.as_s?) || "")
    existing = graph.objects(type: "profile_candidate").any? { |obj| JSON.parse(obj.data)["candidate_identity"]?.try(&.as_s?) == candidate_identity }
    return if existing

    annotation_id = payload["id"]?.try(&.as_s?) || ""
    candidate_data = {
      "candidate_identity"   => JSON::Any.new(candidate_identity),
      "text"                 => JSON::Any.new(body["text"]?.try(&.as_s?) || value),
      "confidence"           => JSON::Any.new(data["confidence"]?.try(&.as_f?) || 0.5),
      "evidence_id"          => data["evidence_id"]? || JSON::Any.new(nil),
      "evidence_identity"    => data["evidence_identity"]? || JSON::Any.new(nil),
      "revision_id"          => data["revision_id"]? || JSON::Any.new(nil),
      "extraction_record_id" => data["run_id"]? || JSON::Any.new(nil),
      "extractor_id"         => data["extractor_id"]? || JSON::Any.new(nil),
      "extractor_version"    => data["extractor_version"]? || JSON::Any.new(nil),
      "extraction_config_id" => data["config_hash"]? || JSON::Any.new(nil),
      "status"               => JSON::Any.new("candidate"),
      "invalidation_reason"  => JSON::Any.new(nil),
      "metadata"             => JSON::Any.new({"projector" => JSON::Any.new("semantic_extraction.profile"), "annotation_id" => JSON::Any.new(annotation_id), "annotation_identity" => data["annotation_identity"]? || JSON::Any.new(nil), "facet" => facet ? JSON::Any.new(facet) : JSON::Any.new(nil), "polarity" => data["polarity"]? || JSON::Any.new(nil)}),
      "attribute"            => JSON::Any.new(attribute),
      "value"                => JSON::Any.new(value),
    }
    candidate = graph.add_object("profile_candidate", JSON::Any.new(candidate_data).to_json)
    graph.add_relation(candidate.id, annotation_id, "projected_from_annotation")
    if evidence_id
      graph.add_relation(candidate.id, evidence_id, "extracted_from")
    end
  end

  # Domain policy: stated assertions become memory candidates.
  @[Chronicle::Packs::Annotations::Behavior(name: "project_memory_candidates", on: ["object.created"], where: {"type" => "semantic_annotation"}, creates: ["memory_candidate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream memory projector
  def project_memory_candidates(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SemanticExtractionSettings) : Nil
    return if !settings.enabled? || !settings.mint_memory_candidates?

    payload = JSON.parse(event.payload).as_h
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "active"
    return unless data["facet"]?.try(&.as_s?) == "assertion"
    return unless data["modality"]?.try(&.as_s?) == "stated"

    annotation_id = payload["id"]?.try(&.as_s?) || ""
    existing = graph.objects(type: "memory_candidate").any? do |obj|
      ((JSON.parse(obj.data)["observation_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)).includes?(annotation_id)
    end
    return if existing

    body = data["body"]?.try(&.as_h) || {} of String => JSON::Any
    text = body["text"]?.try(&.as_s?) || ""
    return if text.empty?

    candidate = graph.add_object("memory_candidate", JSON.build do |json|
      json.object do
        json.field "text", text
        json.field "confidence", data["confidence"]?.try(&.as_f?) || 0.5
        json.field "source_ids", data["evidence_id"]? ? [data["evidence_id"].as_s] : [] of String
        json.field "observation_ids", [annotation_id]
        json.field "category", "context"
        json.field "subject_ref", JSON::Any.new(nil)
        json.field "accepted", false
        json.field "evaluation_id", JSON::Any.new(nil)
        json.field "frame_id", JSON::Any.new(nil)
      end
    end)
    graph.add_relation(candidate.id, annotation_id, "projected_from_annotation")
  end
end

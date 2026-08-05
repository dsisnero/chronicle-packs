require "json"

module Chronicle::Packs::SemanticExtraction
  # Semantic Extraction behaviors. Ported from upstream
  # packs/semantic_extraction/behaviors.py (slice 1: seed_extraction_profile,
  # annotate_evidence). The selection/projection behaviors and the procedure
  # pipeline are deferred.

  # Whether the default profile should route the LLM-only facets to
  # semantic.llm: an LLM provider is configured AND the upgrade isn't
  # switched off. No provider -> the seeded profile (and every downstream
  # byte) is identical to the zero-key mode.
  def self._llm_upgrade_active(settings : SemanticExtractionSettings) : Bool
    return false unless settings.llm_upgrade_enabled?

    Chronicle::Packs::LLMProvider.configured_llm_provider.configured?
  end

  # Seed extraction_profile v1 on pack load if none exists.
  @[Chronicle::Packs::Annotations::Behavior(name: "seed_extraction_profile", on: ["pack.loaded"], where: {"name" => "semantic_extraction"}, creates: ["extraction_profile", "annotation_extractor_state"])]
  def seed_extraction_profile(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SemanticExtractionSettings) : Nil
    return if !settings.seed_default_profile?

    existing = graph.objects(type: "extraction_profile").any? { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    return if existing

    upgraded = _llm_upgrade_active(settings)
    default_facets = settings.default_profile_facets.sort
    extractor_by_facet = {} of String => String
    rationale = "D041: seeded eager facet floor; owner-editable policy artifact (D042)"
    if upgraded
      default_facets = (default_facets.to_set + Facets::LLM_UPGRADE_FACETS.to_set).to_a.sort
      Facets::LLM_UPGRADE_FACETS.each { |facet| extractor_by_facet[facet] = Facets::LLM_EXTRACTOR_REF }
      rationale += "; relation_mention/event_mention upgraded to semantic.llm (provider configured, D025 stage two)"
    end

    profile = ExtractionProfile.new(
      stable_id("extraction_profile", 1), 1, default_facets, "semantic_extraction.seed",
      facets_by_source_category: settings.default_facets_by_source_category.transform_values(&.sort),
      extractor_by_facet: extractor_by_facet,
      rationale: rationale,
    )
    graph.add_object("extraction_profile", profile.to_json)

    if upgraded && !graph.objects(type: "annotation_extractor_state").any? { |obj| JSON.parse(obj.data)["extractor_id"]?.try(&.as_s?) == "semantic.llm" }
      graph.add_object("annotation_extractor_state", JSON.build do |json|
        json.object do
          json.field "state_identity", stable_id("annotation_extractor_state", "semantic.llm", "0.1.0", "candidate")
          json.field "extractor_id", "semantic.llm"
          json.field "extractor_version", "0.1.0"
          json.field "status", "candidate"
          json.field "reason", "fork-trial-promote (ADR 0014): candidate for floor facets pending recorded trial evidence and explicit promotion; serves the LLM-only facets meanwhile"
          json.field "metadata", JSON::Any.new({} of String => JSON::Any)
        end
      end)
    end
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

  # Settle an exact-span request without giving the caller provider access.
  # The pack verifies evidence_id + revision_id and the authoritative span
  # hashes (inside run_profile_extraction) — the model never supplies
  # authoritative offsets. On success the request carries run_ids and
  # annotation_ids; failures settle as failed with a named error.
  @[Chronicle::Packs::Annotations::Behavior(name: "extract_selected_evidence", on: ["object.created"], where: {"type" => "selection_extraction_request"}, creates: ["semantic_annotation", "extraction_run", "extraction_coverage"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream settle-with-failure paths
  def extract_selected_evidence(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SemanticExtractionSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    request_id = payload["id"]?.try(&.as_s?) || ""
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "proposed"
    return if request_id.empty?

    evidence_id = data["evidence_id"]?.try(&.as_s?) || ""
    evidence = evidence_id.empty? ? nil : graph.get_object(evidence_id)
    if evidence.nil? || evidence.type != "activity_evidence"
      _settle_selection(graph, request_id, "evidence_not_found", [] of String, [] of String)
      return
    end
    if JSON.parse(evidence.data)["revision_id"]?.try(&.as_s?) != data["revision_id"]?.try(&.as_s?)
      _settle_selection(graph, request_id, "revision_mismatch", [] of String, [] of String)
      return
    end

    requested_facets = (data["requested_facets"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    selection_id = data["selection_id"]?.try(&.as_s?)
    content_segments = (data["selections"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h)

    begin
      results = run_profile_extraction(
        graph, evidence, settings: settings,
        requested_facets: requested_facets,
        selection_id: selection_id,
        content_segments: content_segments,
      )
    rescue ex
      _settle_selection(graph, request_id, "#{ex.class}: #{ex.message}"[0, 500], [] of String, [] of String)
      return
    end

    run_ids = results.map { |result| result["run"]?.try(&.as_s?) || "" }.reject(&.empty?)
    annotation_ids = results.flat_map { |result| (result["annotations"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s) }
    _settle_selection(graph, request_id, nil, run_ids, annotation_ids)
  end

  private def _settle_selection(graph : Chronicle::GraphProjection, request_id : String, error : String?, run_ids : Array(String), annotation_ids : Array(String)) : Nil
    updates = {
      "status"         => JSON::Any.new(error ? "failed" : "completed"),
      "run_ids"        => JSON::Any.new(run_ids.map { |id| JSON::Any.new(id) }),
      "annotation_ids" => JSON::Any.new(annotation_ids.map { |id| JSON::Any.new(id) }),
    }
    updates["error"] = error ? JSON::Any.new(error) : JSON::Any.new(nil)
    patch(graph, request_id, updates)

    graph.emit(Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: graph.events.size.to_u64 + 1,
      id: "selection_settled_#{graph.events.size + 1}",
      type: "semantic.selection_extraction_settled",
      actor: "semantic_extraction",
      caused_by: nil,
      payload: {
        "request_id"     => JSON::Any.new(request_id),
        "status"         => JSON::Any.new(error ? "failed" : "completed"),
        "run_ids"        => JSON::Any.new(run_ids.map { |id| JSON::Any.new(id) }),
        "annotation_ids" => JSON::Any.new(annotation_ids.map { |id| JSON::Any.new(id) }),
        "error"          => error ? JSON::Any.new(error) : JSON::Any.new(nil),
      }.to_json,
    ))
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

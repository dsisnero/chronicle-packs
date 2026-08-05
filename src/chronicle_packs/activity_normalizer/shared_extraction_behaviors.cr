require "json"

module Chronicle::Packs::ActivityNormalizer
  # ADR 0026 step 2-3 behaviors: the compatibility candidate projectors and
  # the shared-extraction profile selection/migration. Ported from upstream
  # packs/activity_normalizer/behaviors.py (annotations land as
  # semantic_annotation objects via the semantic_extraction seam).

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module SharedExtraction
    STRUCTURE_EXTRACTOR_REF   = "activity.structure@0.2.0"
    COMMUNICATION_FACET_FLOOR = ["entity_mention", "question", "temporal_expression"]
    STACK_OWNED_CREATORS      = ["semantic_extraction.seed", "activity_normalizer.select_shared_extraction"]
  end

  # Compatibility candidate projectors (ADR 0026 step 2): one activity.*
  # annotation -> the same candidate object the legacy direct write path
  # produced, deduped by the LEGACY candidate identity.
  @[Chronicle::Packs::Annotations::Behavior(name: "project_structure_candidates", on: ["object.created"], where: {"type" => "semantic_annotation"}, creates: ["memory_candidate", "preference_candidate", "task_candidate", "profile_candidate", "skill_candidate", "eval_candidate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream projector
  def project_structure_candidates(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    return if !settings.enabled? || !settings.compat_candidate_projectors?

    payload = JSON.parse(event.payload).as_h
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["extractor_id"]?.try(&.as_s?) == "activity.structure"

    facet = data["facet"]?.try(&.as_s?) || ""
    kind = AnnotationExtractor::KIND_BY_FACET[facet]?
    return if kind.nil? || data["status"]?.try(&.as_s?) != "active"

    body = data["body"]?.try(&.as_h) || {} of String => JSON::Any
    text = body["text"]?.try(&.as_s?) || ""
    return if text.empty?

    annotation_id = payload["id"]?.try(&.as_s?) || ""
    evidence_id = data["evidence_id"]?.try(&.as_s?) || ""
    revision_id = data["revision_id"]?.try(&.as_s?) || ""
    evidence_identity = data["evidence_identity"]?.try(&.as_s?) || ""
    metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    ordinal = metadata["ordinal"]?.try(&.as_i?) || 0

    if kind == "memory"
      existing = graph.objects(type: "memory_candidate").any? do |obj|
        cand = JSON.parse(obj.data)
        cand["text"]?.try(&.as_s?) == text && (cand["source_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).includes?(evidence_id)
      end
      return if existing

      candidate = graph.add_object("memory_candidate", JSON.build do |json|
        json.object do
          json.field "text", text
          json.field "confidence", data["confidence"]?.try(&.as_f?) || 0.7
          json.field "source_ids", [evidence_id]
          json.field "observation_ids", [annotation_id]
          json.field "category", body["category"]?.try(&.as_s?) || "context"
          json.field "subject_ref", JSON::Any.new(nil)
          json.field "accepted", false
          json.field "evaluation_id", JSON::Any.new(nil)
          json.field "frame_id", JSON::Any.new(nil)
        end
      end)
      graph.add_relation(candidate.id, annotation_id, "projected_from_annotation")
      graph.add_relation(candidate.id, evidence_id, "extracted_from")
      return
    end

    candidate_type = {
      "preference" => "preference_candidate",
      "task"       => "task_candidate",
      "profile"    => "profile_candidate",
      "skill"      => "skill_candidate",
      "eval"       => "eval_candidate",
    }[kind]
    legacy_identity = _stable_id("candidate", revision_id, settings.default_extractor_id, settings.default_extractor_version, settings.default_extraction_config_id, kind, text, ordinal)
    existing = graph.objects(type: candidate_type).any? { |obj| JSON.parse(obj.data)["candidate_identity"]?.try(&.as_s?) == legacy_identity }
    return if existing

    fields = {} of String => JSON::Any
    body.each do |key, value|
      fields[key] = value unless key.in?({"text", "kind"})
    end
    candidate_data = {
      "candidate_identity"   => JSON::Any.new(legacy_identity),
      "text"                 => JSON::Any.new(text),
      "confidence"           => JSON::Any.new(data["confidence"]?.try(&.as_f?) || 0.7),
      "evidence_id"          => JSON::Any.new(evidence_id),
      "evidence_identity"    => JSON::Any.new(evidence_identity),
      "revision_id"          => JSON::Any.new(revision_id),
      "extraction_record_id" => data["run_id"]? || JSON::Any.new(nil),
      "extractor_id"         => data["extractor_id"]? || JSON::Any.new(nil),
      "extractor_version"    => data["extractor_version"]? || JSON::Any.new(nil),
      "extraction_config_id" => data["config_hash"]? || JSON::Any.new(nil),
      "status"               => JSON::Any.new("candidate"),
      "invalidation_reason"  => JSON::Any.new(nil),
      "metadata"             => JSON::Any.new({"projector" => JSON::Any.new("activity_normalizer.compat"), "annotation_id" => JSON::Any.new(annotation_id), "annotation_identity" => data["annotation_identity"]? || JSON::Any.new(nil)}),
    }
    fields.each { |key, value| candidate_data[key] = value }
    candidate = graph.add_object(candidate_type, JSON::Any.new(candidate_data).to_json)
    graph.add_relation(candidate.id, annotation_id, "projected_from_annotation")
    graph.add_relation(candidate.id, evidence_id, "extracted_from")
  end

  # Route the activity.* structure facets onto the shared layer the moment its
  # default profile appears (ADR 0026: curated selection, no long legacy window).
  @[Chronicle::Packs::Annotations::Behavior(name: "select_shared_extraction", on: ["object.created"], where: {"type" => "extraction_profile"}, creates: ["extraction_profile"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream selection behavior
  def select_shared_extraction(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    return if !settings.enabled? || !settings.select_shared_extraction?
    return if settings.legacy_extraction_enabled?

    payload = JSON.parse(event.payload).as_h
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    profile_id = payload["id"]?.try(&.as_s?)
    return if profile_id.nil?
    return unless data["version"]?.try(&.as_i?) == 1 && data["status"]?.try(&.as_s?) == "active"

    routed = data["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any
    return if AnnotationExtractor::STRUCTURE_FACETS.any? { |facet| routed.has_key?(facet) }

    higher = graph.objects(type: "extraction_profile").any? { |obj| (JSON.parse(obj.data)["version"]?.try(&.as_i) || 0) > 1 }
    return if higher

    extractor_by_facet = routed.dup
    AnnotationExtractor::STRUCTURE_FACETS.each { |facet| extractor_by_facet[facet] = JSON::Any.new(SharedExtraction::STRUCTURE_EXTRACTOR_REF) }
    default_facets = ((data["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String) + AnnotationExtractor::STRUCTURE_FACETS).to_set.to_a.sort
    profile = Chronicle::Packs::SemanticExtraction::ExtractionProfile.new(
      _stable_id("extraction_profile", 2), 2, default_facets, "activity_normalizer.select_shared_extraction",
      facets_by_source_category: (data["facets_by_source_category"]?.try(&.as_h) || {} of String => JSON::Any).transform_values { |facets| facets.as_a.map(&.as_s) },
      extractor_by_facet: extractor_by_facet.transform_values(&.as_s),
      rationale: "ADR 0026 steps 2-3: activity structure extraction moves onto the shared annotation layer; the direct evidence→candidate write path is disabled",
      supersedes_profile_id: profile_id,
    )
    graph.add_object("extraction_profile", profile.to_json)
    if current = graph.get_object(profile_id)
      old_data = JSON.parse(current.data).as_h
      old_data["status"] = JSON::Any.new("superseded")
      graph.patch_object(profile_id, JSON::Any.new(old_data).to_json)
    end
  end

  # Upgrade only stack-owned legacy profiles on replayed stores.
  @[Chronicle::Packs::Annotations::Behavior(name: "migrate_communication_extraction_floor", on: ["pack.loaded"], where: {"name" => "activity_normalizer"}, creates: ["extraction_profile"])]
  def migrate_communication_extraction_floor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    profiles = graph.objects(type: "extraction_profile").sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }
    active = profiles.reverse.find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    return if active.nil?

    data = JSON.parse(active.data).as_h
    return unless SharedExtraction::STACK_OWNED_CREATORS.includes?(data["created_by"]?.try(&.as_s?) || "")

    by_category = (data["facets_by_source_category"]?.try(&.as_h) || {} of String => JSON::Any).dup
    return if by_category.has_key?("communication")

    version = (profiles.max_of? { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 } || 0) + 1
    by_category["communication"] = JSON::Any.new(SharedExtraction::COMMUNICATION_FACET_FLOOR.map { |facet| JSON::Any.new(facet) })
    profile = Chronicle::Packs::SemanticExtraction::ExtractionProfile.new(
      _stable_id("extraction_profile", version), version,
      data["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      "activity_normalizer.communication_floor_migration",
      facets_by_source_category: by_category.transform_values { |facets| facets.as_a.map(&.as_s) },
      extractor_by_facet: (data["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any).transform_values(&.as_s),
      rationale: "ADR 0031: bound eager extraction for high-volume, multi-subject communication",
      supersedes_profile_id: active.id,
    )
    graph.add_object("extraction_profile", profile.to_json)
    if current = graph.get_object(active.id)
      old_data = JSON.parse(current.data).as_h
      old_data["status"] = JSON::Any.new("superseded")
      graph.patch_object(active.id, JSON::Any.new(old_data).to_json)
    end
  end
end

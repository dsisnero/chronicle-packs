require "json"
require "digest"

module Chronicle::Packs::SemanticExtraction
  # The shared annotation extraction engine. Ported from upstream
  # packs/semantic_extraction/engine.py (slice 1: the eager profile-driven
  # path with cache idempotency; procedure routing is deferred, so the
  # extractor_map is always empty and extraction is one default-extractor
  # pass, byte-identical to the single-extractor behavior).

  def self.stable_id(prefix : String, *parts) : String
    material = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  def self._active_profile(graph : Chronicle::GraphProjection) : Chronicle::GraphObject?
    profiles = graph.objects(type: "extraction_profile").select { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    return nil if profiles.empty?

    profiles.sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }
    profiles.last
  end

  # Requested facets for one source category, from the config artifact.
  def self.active_profile_facets(graph : Chronicle::GraphProjection, source_category : String, fallback : Array(String)) : Array(String)
    profile = _active_profile(graph)
    if profile.nil?
      return fallback.sort
    end
    data = JSON.parse(profile.data).as_h
    per_category = data["facets_by_source_category"]?.try(&.as_h) || {} of String => JSON::Any
    facets = per_category[source_category]?.try(&.as_a?.try(&.map(&.as_s))) || data["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    facets.empty? ? fallback.sort : facets.sort
  end

  # facet → 'extractor_id@version' from the active profile (empty by default).
  def self.active_profile_extractor_map(graph : Chronicle::GraphProjection) : Hash(String, String)
    profile = _active_profile(graph)
    return {} of String => String if profile.nil?

    (JSON.parse(profile.data)["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any).transform_values(&.as_s)
  end

  def self.extractor_disabled(graph : Chronicle::GraphProjection, extractor_id : String, extractor_version : String) : Bool
    states = graph.objects(type: "annotation_extractor_state").select do |obj|
      data = JSON.parse(obj.data)
      data["extractor_id"]?.try(&.as_s?) == extractor_id && data["extractor_version"]?.try(&.as_s?) == extractor_version
    end
    states.any? { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "disabled" }
  end

  def self._attribution(normalized_metadata : Hash(String, JSON::Any)) : {String, String?}
    role = normalized_metadata["role"]?.try(&.as_s?)
    if role.in?({"user", "human", "owner"})
      return {"subject_self", role}
    end
    if role.in?({"assistant", "model", "tool", "system"})
      return {"author_about_subject", role}
    end
    {"unknown", role}
  end

  # Facets any prior completed run of this extractor identity executed.
  def self._facets_covered(graph : Chronicle::GraphProjection, revision_id : String, extractor_id : String, extractor_version : String, config_hash : String, selection_id : String?) : Set(String)
    covered = Set(String).new
    graph.objects(type: "extraction_run").each do |obj|
      data = JSON.parse(obj.data).as_h
      if data["revision_id"]?.try(&.as_s?) == revision_id &&
         data["extractor_id"]?.try(&.as_s?) == extractor_id &&
         data["extractor_version"]?.try(&.as_s?) == extractor_version &&
         data["config_hash"]?.try(&.as_s?) == config_hash &&
         data["selection_id"]?.try(&.as_s?) == selection_id &&
         data["status"]?.try(&.as_s?) == "completed"
        (data["executed_facets"]?.try(&.as_a) || [] of JSON::Any).each { |facet_ref| covered << facet_ref.as_s }
      end
    end
    covered
  end

  def self.annotation_identity_for(revision_id : String, extractor_id : String, extractor_version : String, config_hash : String, draft : AnnotationDraft) : String
    body_canonical = draft.body.to_a.sort_by(&.[0]).map { |key, value| "#{key}=#{value}" }.join("\x1e")
    stable_id("annotation", revision_id, extractor_id, extractor_version, config_hash, draft.facet, draft.start, draft.end, body_canonical)
  end

  # Merge-append patch (chronicle's patch_object replaces).
  def self.patch(graph : Chronicle::GraphProjection, target : String, updates : Hash(String, JSON::Any)) : Nil
    current = graph.get_object(target)
    return if current.nil?

    data = JSON.parse(current.data).as_h
    updates.each { |key, value| data[key] = value }
    graph.patch_object(target, JSON::Any.new(data).to_json)
  end

  # Execute (or cache-hit) one extraction over one evidence revision.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream extraction pipeline
  def self.run_annotation_extraction(graph : Chronicle::GraphProjection, evidence_obj : Chronicle::GraphObject, settings : SemanticExtractionSettings, requested_facets : Array(String)? = nil, extractor_ref : String? = nil, selection_id : String? = nil, content_segments : Array(Hash(String, JSON::Any))? = nil) : Hash(String, JSON::Any)
    evidence = JSON.parse(evidence_obj.data).as_h
    extractor = extractor_ref ? Extractors.get_annotation_extractor(*_parse_extractor_ref(extractor_ref)) : Extractors.get_annotation_extractor(settings.extractor_id, settings.extractor_version)
    config_hash = config_hash_for(extractor.config)

    facets = requested_facets || active_profile_facets(graph, evidence["source_category"]?.try(&.as_s?) || "", settings.default_profile_facets)
    requested = facets.to_set.to_a.sort
    revision_id = evidence["revision_id"].as_s

    run_identity = stable_id("extraction_run", revision_id, extractor.extractor_id, extractor.extractor_version, config_hash, requested.join(","), selection_id || "full_evidence")
    existing = graph.objects(type: "extraction_run").find { |obj| JSON.parse(obj.data)["run_identity"]?.try(&.as_s?) == run_identity }
    if existing
      return {"ok" => JSON::Any.new(true), "run" => JSON::Any.new(existing.id), "created" => JSON::Any.new(false), "annotations" => JSON::Any.new([] of JSON::Any)}
    end

    if extractor_disabled(graph, extractor.extractor_id, extractor.extractor_version)
      raise Chronicle::Packs::PackError.new("annotation extractor is disabled: #{extractor.extractor_id}@#{extractor.extractor_version}")
    end

    covered = _facets_covered(graph, revision_id, extractor.extractor_id, extractor.extractor_version, config_hash, selection_id)
    implemented = extractor.implemented_facets.to_set
    cached = requested.select { |facet| covered.includes?(facet) }
    missing = requested.select { |facet| !covered.includes?(facet) && implemented.includes?(facet) }
    unimplemented = requested.select { |facet| !covered.includes?(facet) && !implemented.includes?(facet) }

    content = evidence["normalized_content"]?.try(&.as_s?) || ""
    normalized_metadata = evidence["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
    attribution, author_role = _attribution(normalized_metadata)
    observation_time = evidence["provider_time"]?.try(&.as_s?)

    selected_chars = content.size
    if content_segments
      verified_segments = [] of {Int32, String}
      selected_chars = 0
      content_segments.each do |segment|
        start = segment["start"]?.try(&.as_i?) || -1
        stop = segment["end"]?.try(&.as_i?) || -1
        raise Chronicle::Packs::PackError.new("selection span is outside authoritative evidence") if start < 0 || stop < start || stop > content.size

        exact = content[start...stop]
        if Digest::SHA256.hexdigest(exact) != segment["exact_hash"]?.try(&.as_s?)
          raise Chronicle::Packs::PackError.new("selection hash does not match authoritative evidence")
        end
        verified_segments << {start, exact}
        selected_chars += exact.size
      end
      drafts = [] of AnnotationDraft
      per_facet = {} of String => Int32
      if !missing.empty?
        verified_segments.each do |offset, exact|
          extractor.extract(exact, normalized_metadata, missing).each do |draft|
            count = per_facet[draft.facet]? || 0
            next if count >= settings.max_annotations_per_facet

            per_facet[draft.facet] = count + 1
            meta = draft.metadata.dup
            meta["selection_id"] = JSON::Any.new(selection_id)
            drafts << AnnotationDraft.new(draft.facet, draft.body, draft.start + offset, draft.end + offset, draft.exact, draft.confidence, draft.modality, draft.polarity, draft.event_time, meta)
          end
        end
      end
    else
      drafts = missing.empty? ? [] of AnnotationDraft : extractor.extract(content, normalized_metadata, missing)
    end

    run = ExtractionRun.new(
      run_identity, evidence_obj.id, evidence["evidence_identity"].as_s, revision_id,
      extractor.extractor_id, extractor.extractor_version, config_hash, requested,
      selection_id: selection_id, executed_facets: missing, cached_facets: cached,
      metadata: {"acquired_at_event_id" => evidence["acquired_at_event_id"]? || JSON::Any.new(nil), "selection_count" => JSON::Any.new(content_segments ? content_segments.size : 0)},
    )
    run_obj = graph.add_object("extraction_run", run.to_json)
    graph.add_relation(run_obj.id, evidence_obj.id, "run_for")

    seen_identities = graph.objects(type: "semantic_annotation").select { |obj| JSON.parse(obj.data)["revision_id"]?.try(&.as_s?) == revision_id }.map { |obj| JSON.parse(obj.data)["annotation_identity"]?.try(&.as_s?) }.to_set
    annotation_ids = [] of String
    drafts.each do |draft|
      identity = annotation_identity_for(revision_id, extractor.extractor_id, extractor.extractor_version, config_hash, draft)
      next if seen_identities.includes?(identity)

      seen_identities << identity
      annotation_record = SemanticAnnotation.new(
        identity, draft.facet, validate_body(draft.facet, draft.body),
        evidence_obj.id, evidence["evidence_identity"].as_s, revision_id,
        {"kind" => JSON::Any.new("char_span"), "start" => JSON::Any.new(draft.start), "end" => JSON::Any.new(draft.end), "exact" => JSON::Any.new(draft.exact)},
        extractor.extractor_id, extractor.extractor_version, config_hash, draft.confidence,
        run_obj.id,
        attribution: attribution, author_role: author_role,
        event_time: draft.event_time, observation_time: observation_time,
        modality: draft.modality, polarity: draft.polarity,
        metadata: begin
          annotation_metadata = draft.metadata.dup
          annotation_metadata["source_category"] = evidence["source_category"]? || JSON::Any.new("")
          subject_scope = normalized_metadata["subject_scope"]?.try(&.as_s?)
          annotation_metadata["subject_scope"] = subject_scope ? JSON::Any.new(subject_scope) : JSON::Any.new(nil)
          annotation_metadata["profile_candidate_eligible"] = JSON::Any.new(subject_scope == "owner_profile")
          annotation_metadata["memory_candidate_eligible"] = JSON::Any.new(
            evidence["source_category"]?.try(&.as_s?) != "communication" || subject_scope == "owner_profile",
          )
          annotation_metadata
        end,
      )
      annotation_obj = graph.add_object("semantic_annotation", annotation_record.to_json)
      graph.add_relation(annotation_obj.id, evidence_obj.id, "annotation_for")
      graph.add_relation(run_obj.id, annotation_obj.id, "produced_annotation")
      annotation_ids << annotation_obj.id
    end
    if !annotation_ids.empty?
      patch(graph, run_obj.id, {"annotation_ids" => JSON::Any.new(annotation_ids.map { |id| JSON::Any.new(id) })})
    end

    coverage = ExtractionCoverage.new(
      stable_id("extraction_coverage", run_identity), run_obj.id, evidence_obj.id, revision_id,
      content.size, selected_chars,
      processed_facets: missing + cached, skipped_facets: unimplemented.map { |facet| {"facet" => JSON::Any.new(facet), "reason" => JSON::Any.new("not_implemented")} },
      truncated: content.size > settings.max_content_chars,
    )
    coverage_obj = graph.add_object("extraction_coverage", coverage.to_json)
    graph.add_relation(coverage_obj.id, run_obj.id, "coverage_for")

    {"ok" => JSON::Any.new(true), "run" => JSON::Any.new(run_obj.id), "created" => JSON::Any.new(true), "annotations" => JSON::Any.new(annotation_ids.map { |id| JSON::Any.new(id) })}
  end

  def self._parse_extractor_ref(ref : String) : {String, String}
    parts = ref.split("@")
    {parts[0], parts.size > 1 ? parts[1] : "0.1.0"}
  end

  # Extract per the active profile's facet policy (single default extractor).
  def self.run_profile_extraction(graph : Chronicle::GraphProjection, evidence_obj : Chronicle::GraphObject, settings : SemanticExtractionSettings, requested_facets : Array(String)? = nil, selection_id : String? = nil, content_segments : Array(Hash(String, JSON::Any))? = nil) : Array(Hash(String, JSON::Any))
    evidence = JSON.parse(evidence_obj.data).as_h
    facets = requested_facets || active_profile_facets(graph, evidence["source_category"]?.try(&.as_s?) || "", settings.default_profile_facets)
    requested = facets.to_set.to_a.sort
    [run_annotation_extraction(graph, evidence_obj, settings, requested_facets: requested, selection_id: selection_id, content_segments: content_segments)]
  end
end

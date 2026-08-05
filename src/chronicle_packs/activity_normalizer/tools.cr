require "json"

module Chronicle::Packs::ActivityNormalizer
  # Graph-visible replay and extractor-lifecycle capabilities. Ported from
  # upstream packs/activity_normalizer/tools.py.

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Record a replay/reextraction failure, optionally flipping replay_complete.
  def self._reextract_failure(graph : Chronicle::GraphProjection, evidence : Chronicle::GraphObject, data : Hash(String, JSON::Any), ex : Exception, chosen_id : String, chosen_version : String) : Hash(String, JSON::Any)
    if ex.is_a?(Replay::ReplayError) && (data["replay_complete"]?.try(&.as_bool?) || false)
      current = JSON.parse(evidence.data).as_h
      current["replay_complete"] = JSON::Any.new(false)
      _patch(graph, evidence.id, current)
    end
    failure = record_failure(
      graph, stage: ex.is_a?(Replay::ReplayError) ? "replay" : "extraction",
      error_code: ex.is_a?(Replay::ReplayError) ? "replay_unavailable" : "reextraction_failed",
      message: "#{ex.class}: #{ex}",
      source_surface_id: data["source_surface_id"]?.try(&.as_s?),
      acquired_item_id: data["acquired_item_id"]?.try(&.as_s?),
      source_ref: data["source_ref"]?.try(&.as_s?),
      importer_id: data["importer_id"]?.try(&.as_s?),
      importer_version: data["importer_version"]?.try(&.as_s?),
      extractor_id: chosen_id, extractor_version: chosen_version,
    )
    {"ok" => JSON::Any.new(false), "failure_id" => JSON::Any.new(failure.id)}
  end

  # Emit the replay.verified domain event for a successful re-extraction.
  def self._emit_replay_verified(graph : Chronicle::GraphProjection, evidence : Chronicle::GraphObject, data : Hash(String, JSON::Any), record_id : String, chosen_id : String, chosen_version : String, chosen_config : String) : Chronicle::Event
    _emit_event(graph, "replay.verified", {
      "evidence_id"          => JSON::Any.new(evidence.id),
      "evidence_identity"    => data["evidence_identity"]? || JSON::Any.new(nil),
      "revision_id"          => data["revision_id"]? || JSON::Any.new(nil),
      "extraction_record_id" => JSON::Any.new(record_id),
      "extractor_id"         => JSON::Any.new(chosen_id),
      "extractor_version"    => JSON::Any.new(chosen_version),
      "extraction_config_id" => JSON::Any.new(chosen_config),
      "replay_payload_hash"  => data["replay_payload_hash"]? || JSON::Any.new(nil),
    }, caused_by: nil)
  end

  # Re-extract only from retained payload; never dereference source_ref.
  def self.reextract_evidence_fn(graph : Chronicle::GraphProjection, evidence_id : String, settings : ActivityNormalizerSettings, extractor_id : String? = nil, extractor_version : String? = nil, extraction_config_id : String? = nil) : Hash(String, JSON::Any)
    evidence = graph.get_object(evidence_id)
    raise Chronicle::Packs::PackError.new("unknown activity_evidence: #{evidence_id}") if evidence.nil? || evidence.type != "activity_evidence"

    data = JSON.parse(evidence.data).as_h
    chosen_id = extractor_id || settings.default_extractor_id
    chosen_version = extractor_version || settings.default_extractor_version
    chosen_config = extraction_config_id || settings.default_extraction_config_id
    begin
      result = _attempt_reextraction(graph, evidence, data, settings, chosen_id, chosen_version, chosen_config)
    rescue ex : Replay::ReplayError | ArgumentError | JSON::ParseException | KeyError | RuntimeError
      return _reextract_failure(graph, evidence, data, ex, chosen_id, chosen_version)
    end

    record_id = result["record"].as_s
    event = _emit_replay_verified(graph, evidence, data, record_id, chosen_id, chosen_version, chosen_config)
    {"ok" => JSON::Any.new(true), "extraction_record_id" => JSON::Any.new(record_id), "replay_event_id" => JSON::Any.new(event.id), "created" => result["created"]}
  end

  # Load retained payload, normalize, and run the versioned extractor.
  private def self._attempt_reextraction(graph : Chronicle::GraphProjection, evidence : Chronicle::GraphObject, data : Hash(String, JSON::Any), settings : ActivityNormalizerSettings, chosen_id : String, chosen_version : String, chosen_config : String) : Hash(String, JSON::Any)
    payload = Replay.read_replay_payload(data, settings)
    content, replay_metadata = normalize_replay_payload(
      payload,
      data["media_type"]?.try(&.as_s?) || "",
      encoding: data["encoding"]?.try(&.as_s?) || settings.encoding,
      max_chars: settings.max_normalized_content_chars,
    )
    metadata = (data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
    replay_metadata.each { |key, value| metadata[key] = value }
    run_extraction(
      graph, evidence, content, metadata, settings,
      extractor_id: chosen_id, extractor_version: chosen_version,
      extraction_config_id: chosen_config, replayed: true, replay_verified: true,
    )
  end

  # Invalidate an extractor version's candidate provenance, preserving evidence.
  def self.disable_extractor_version_fn(graph : Chronicle::GraphProjection, extractor_id : String, extractor_version : String, reason : String, extraction_config_id : String? = nil) : Hash(String, JSON::Any)
    state_identity = "#{extractor_id}@#{extractor_version}" + (extraction_config_id ? "##{extraction_config_id}" : "")
    event = _emit_event(graph, "extractor.disabled", {
      "state_identity"       => JSON::Any.new(state_identity),
      "extractor_id"         => JSON::Any.new(extractor_id),
      "extractor_version"    => JSON::Any.new(extractor_version),
      "extraction_config_id" => extraction_config_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
      "reason"               => JSON::Any.new(reason),
    }, caused_by: nil)
    state = graph.add_object("extractor_version_state", JSON.build do |json|
      json.object do
        json.field "state_identity", state_identity
        json.field "extractor_id", extractor_id
        json.field "extractor_version", extractor_version
        json.field "extraction_config_id", extraction_config_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil)
        json.field "status", "disabled"
        json.field "reason", reason
        json.field "changed_at_event_id", event.id
      end
    end)

    invalidated_records = 0
    invalidated_candidates = 0
    graph.objects(type: "extraction_record").each do |record|
      record_data = JSON.parse(record.data).as_h
      next unless record_data["extractor_id"]?.try(&.as_s?) == extractor_id
      next unless record_data["extractor_version"]?.try(&.as_s?) == extractor_version
      next if extraction_config_id && record_data["extraction_config_id"]?.try(&.as_s?) != extraction_config_id
      if record_data["status"]?.try(&.as_s?) != "invalidated"
        current_record = JSON.parse(record.data).as_h
        current_record["status"] = JSON::Any.new("invalidated")
        _patch(graph, record.id, current_record)
        invalidated_records += 1
      end
      (record_data["candidate_ids"]?.try(&.as_a) || [] of JSON::Any).each do |candidate_ref|
        candidate = graph.get_object(candidate_ref.as_s)
        next if candidate.nil?
        if candidate.type == "memory_candidate"
          graph.add_object("evaluation", JSON.build do |json|
            json.object do
              json.field "subject_id", candidate.id
              json.field "subject_type", "memory_candidate"
              json.field "judgment", "invalidated"
              json.field "rationale", reason
              json.field "evaluator", "activity_normalizer.disable_extractor_version"
              json.field "score", JSON::Any.new(nil)
              json.field "frame_id", JSON::Any.new(nil)
              json.field "metadata", JSON::Any.new({"extractor_id" => JSON::Any.new(extractor_id), "extractor_version" => JSON::Any.new(extractor_version)})
            end
          end)
        else
          current_candidate = JSON.parse(candidate.data).as_h
          current_candidate["status"] = JSON::Any.new("invalidated")
          current_candidate["invalidation_reason"] = JSON::Any.new(reason)
          _patch(graph, candidate.id, current_candidate)
        end
        invalidated_candidates += 1
      end
    end
    {"ok" => JSON::Any.new(true), "state_id" => JSON::Any.new(state.id), "event_id" => JSON::Any.new(event.id), "invalidated_records" => JSON::Any.new(invalidated_records), "invalidated_candidates" => JSON::Any.new(invalidated_candidates)}
  end

  @[Chronicle::Packs::Annotations::Tool(name: "reextract_evidence", description: "Re-run a versioned extractor from retained replay input without source access.", deterministic: true)]
  def reextract_evidence_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = reextract_evidence_fn(
      bound_graph_or_raise,
      input["evidence_id"]?.try(&.as_s?) || "",
      settings: ActivityNormalizerSettings.from_json(%({"artifact_store_dir": "#{input["artifact_store_dir"]?.try(&.as_s?) || ".activegraph/replay-artifacts"}"})),
      extractor_id: input["extractor_id"]?.try(&.as_s?),
      extractor_version: input["extractor_version"]?.try(&.as_s?),
      extraction_config_id: input["extraction_config_id"]?.try(&.as_s?),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "disable_extractor_version", description: "Disable an extractor version and invalidate its candidate provenance.", deterministic: true)]
  def disable_extractor_version_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = disable_extractor_version_fn(
      bound_graph_or_raise,
      input["extractor_id"]?.try(&.as_s?) || "",
      input["extractor_version"]?.try(&.as_s?) || "0.1.0",
      reason: input["reason"]?.try(&.as_s?) || "disabled by explicit operator action",
      extraction_config_id: input["extraction_config_id"]?.try(&.as_s?),
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "activity_normalizer tools require a bound graph (set ActivityNormalizer.bound_graph)"
    )
  end
end

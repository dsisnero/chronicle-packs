require "json"
require "digest"

module Chronicle::Packs::ActivityNormalizer
  # Identity-owning normalization, deterministic extraction, and
  # cursor/tombstone behaviors. Ported from upstream
  # packs/activity_normalizer/behaviors.py.
  #
  # Chronicle differences: object.created payload is flat ({id, type, data}),
  # ctx has no read view (graph serves reads), and patch_object replaces the
  # full object — so supersede/invalidation merges are explicit. The ADR 0026
  # shared-extraction behaviors (migrate_communication_extraction_floor,
  # select_shared_extraction, project_structure_candidates) depend on the
  # semantic_extraction pack's types and are deferred until it lands.

  class_property event_seq = 0_u64

  # Stable sha256-based identity, mirroring upstream _stable_id.
  def self._stable_id(prefix : String, *parts) : String
    material = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  # Emit one immutable domain event using the graph's recorded clock.
  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any), caused_by : String?, actor : String = "activity_normalizer") : Chronicle::Event
    seq = (self.event_seq += 1)
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{event_type.gsub('.', "_")}_#{seq}",
      type: event_type, actor: actor, caused_by: caused_by,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
  end

  # Merge-append patch: chronicle's patch_object replaces the whole object,
  # so read the current projection, overlay the updates, and write it back.
  def self._patch(graph : Chronicle::GraphProjection, target : String, updates : Hash(String, JSON::Any)) : Nil
    current = graph.get_object(target)
    return if current.nil?

    data = JSON.parse(current.data).as_h
    updates.each { |key, value| data[key] = value }
    graph.patch_object(target, JSON::Any.new(data).to_json)
  end

  # Record a non-partial ingestion failure and link it to its acquired item.
  def self.record_failure(graph : Chronicle::GraphProjection, stage : String, error_code : String, message : String, source_surface_id : String? = nil, acquired_item_id : String? = nil, source_ref : String? = nil, importer_id : String? = nil, importer_version : String? = nil, extractor_id : String? = nil, extractor_version : String? = nil, recoverable : Bool = false, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : Chronicle::GraphObject
    failure = IngestionFailure.new(stage, error_code, message[0, 2000] || error_code, source_surface_id, acquired_item_id, source_ref, importer_id, importer_version, extractor_id, extractor_version, recoverable, metadata)
    obj = graph.add_object("ingestion_failure", failure.to_json)
    target = acquired_item_id.try { |id| graph.get_object(id) }
    if target && (item_id = acquired_item_id)
      graph.add_relation(obj.id, item_id, "failure_for")
    end
    obj
  end

  # Derive bounded reasoning text from the exact retained replay payload.
  def self.normalize_replay_payload(payload : Bytes, media_type : String, encoding : String, max_chars : Int32) : {String, Hash(String, JSON::Any)}
    text = String.new(payload, encoding)
    metadata = {} of String => JSON::Any
    if media_type == "application/json" || media_type.ends_with?("+json")
      parsed = JSON.parse(text)
      if hash = parsed.as_h?
        text, metadata = _json_object_text(hash, metadata)
      else
        text = parsed.to_json
      end
    end
    text = text.gsub("\r\n", "\n").gsub("\r", "\n").strip
    {text[0, max_chars], metadata}
  end

  # Extract reasoning text and scalar metadata from a JSON replay payload.
  private def self._json_object_text(hash : Hash(String, JSON::Any), metadata : Hash(String, JSON::Any)) : {String, Hash(String, JSON::Any)}
    if key = %w(normalized_content text).find { |candidate| hash[candidate]?.try(&.as_s?) }
      hash.each do |k, v|
        next if k == key || !v.raw.is_a?(String) && !v.raw.is_a?(Number) && !v.raw.is_a?(Bool) && !v.raw.is_a?(Array) && !v.raw.is_a?(Hash)
        metadata[k] = v
      end
      {hash[key].as_s, metadata}
    else
      content = hash["content"]?
      text = case
             when content.nil?                                    then _sorted_json(hash)
             when content.as_s?                                   then content.as_s
             when content.as_h? && content["parts"]?.try(&.as_a?) then content["parts"].as_a.compact_map(&.as_s?).join("\n")
             else                                                      _sorted_json(hash)
             end
      {text, metadata}
    end
  end

  # Deterministically serialize a JSON object with sorted keys (upstream
  # json.dumps(sort_keys=True) parity).
  def self._sorted_json(hash : Hash(String, JSON::Any)) : String
    JSON.build do |json|
      json.object do
        hash.to_a.sort_by(&.[0]).each { |key, value| json.field key, value }
      end
    end
  end

  # The acquired_content handoff paired with an acquired item.
  def self._content_for(graph : Chronicle::GraphProjection, acquired_item_id : String) : Chronicle::GraphObject?
    graph.objects(type: "acquired_content").find { |obj| AcquiredContent.from_json(obj.data).acquired_item_id == acquired_item_id }
  end

  # Whether the newest extractor_version_state for this config is disabled.
  def self._extractor_disabled(graph : Chronicle::GraphProjection, extractor_id : String, extractor_version : String, extraction_config_id : String) : Bool
    graph.objects(type: "extractor_version_state").any? do |obj|
      state = ExtractorVersionState.from_json(obj.data)
      state.extractor_id == extractor_id && state.extractor_version == extractor_version &&
        state.extraction_config_id.in?({nil, extraction_config_id}) && state.status == "disabled"
    end
  end

  # Deterministic candidate identity for one extractor run ordinal.
  def self._candidate_identity(evidence : ActivityEvidence, extractor_id : String, extractor_version : String, extraction_config_id : String, draft : CandidateDraft, ordinal : Int32) : String
    _stable_id("candidate", evidence.revision_id, extractor_id, extractor_version, extraction_config_id, draft.kind, draft.text, ordinal)
  end

  # Draft field lookup with a default (draft.fields are provider-neutral).
  def self._draft_field(draft : CandidateDraft, key : String, default : String) : String
    draft.fields[key]?.try(&.as_s?) || default
  end

  def self._candidate_json(kind : String, evidence : ActivityEvidence, evidence_id : String, extraction_record_id : String, draft : CandidateDraft, candidate_identity : String, extractor_id : String, extractor_version : String, extraction_config_id : String) : String
    case kind
    when "memory"
      JSON.build do |json|
        json.object do
          json.field "text", draft.text
          json.field "confidence", draft.confidence
          json.field "source_ids", [evidence.acquired_item_id]
          json.field "observation_ids", [] of String
          json.field "category", _draft_field(draft, "category", "context")
          json.field "subject_ref", JSON::Any.new(nil)
          json.field "accepted", false
          json.field "evaluation_id", JSON::Any.new(nil)
          json.field "frame_id", JSON::Any.new(nil)
        end
      end
    when "preference"
      PreferenceCandidate.new(candidate_identity, draft.text, evidence_id, evidence.evidence_identity, evidence.revision_id, extraction_record_id, extractor_id, extractor_version, extraction_config_id, confidence: draft.confidence, preference: _draft_field(draft, "preference", draft.text)).to_json
    when "task"
      TaskCandidate.new(candidate_identity, draft.text, evidence_id, evidence.evidence_identity, evidence.revision_id, extraction_record_id, extractor_id, extractor_version, extraction_config_id, confidence: draft.confidence, title: _draft_field(draft, "title", draft.text[0, 120])).to_json
    when "profile"
      ProfileCandidate.new(candidate_identity, draft.text, evidence_id, evidence.evidence_identity, evidence.revision_id, extraction_record_id, extractor_id, extractor_version, extraction_config_id, confidence: draft.confidence, attribute: _draft_field(draft, "attribute", "profile_statement"), value: _draft_field(draft, "value", draft.text)).to_json
    when "skill"
      SkillCandidate.new(candidate_identity, draft.text, evidence_id, evidence.evidence_identity, evidence.revision_id, extraction_record_id, extractor_id, extractor_version, extraction_config_id, confidence: draft.confidence, name: _draft_field(draft, "name", draft.text[0, 120]), description: _draft_field(draft, "description", draft.text)).to_json
    when "eval"
      EvalCandidate.new(candidate_identity, draft.text, evidence_id, evidence.evidence_identity, evidence.revision_id, extraction_record_id, extractor_id, extractor_version, extraction_config_id, confidence: draft.confidence, subject: _draft_field(draft, "subject", "source_activity"), judgment: _draft_field(draft, "judgment", draft.text)).to_json
    else
      raise "unknown candidate kind: #{kind}"
    end
  end

  def self._create_candidate(graph : Chronicle::GraphProjection, evidence_obj : Chronicle::GraphObject, extraction_record_id : String, draft : CandidateDraft, candidate_identity : String, extractor_id : String, extractor_version : String, extraction_config_id : String) : Chronicle::GraphObject
    evidence = ActivityEvidence.from_json(evidence_obj.data)
    candidate_type = {"memory" => "memory_candidate", "preference" => "preference_candidate", "task" => "task_candidate", "profile" => "profile_candidate", "skill" => "skill_candidate", "eval" => "eval_candidate"}[draft.kind]
    candidate = graph.add_object(candidate_type, _candidate_json(draft.kind, evidence, evidence_obj.id, extraction_record_id, draft, candidate_identity, extractor_id, extractor_version, extraction_config_id))
    graph.add_relation(extraction_record_id, candidate.id, "produced_candidate")
    graph.add_relation(candidate.id, evidence_obj.id, "extracted_from")
    candidate
  end

  # Run one immutable extractor/config identity idempotently.
  def self.run_extraction(graph : Chronicle::GraphProjection, evidence_obj : Chronicle::GraphObject, content : String, normalized_metadata : Hash(String, JSON::Any), settings : ActivityNormalizerSettings, extractor_id : String, extractor_version : String, extraction_config_id : String, replayed : Bool = false, replay_verified : Bool = false) : Hash(String, JSON::Any)
    evidence = ActivityEvidence.from_json(evidence_obj.data)
    extraction_identity = _stable_id("extraction", evidence.revision_id, extractor_id, extractor_version, extraction_config_id)
    existing = graph.objects(type: "extraction_record").find { |obj| ExtractionRecord.from_json(obj.data).extraction_identity == extraction_identity }
    if existing
      return {"ok" => JSON::Any.new(ExtractionRecord.from_json(existing.data).status == "completed"), "record" => JSON::Any.new(existing.id), "created" => JSON::Any.new(false)}
    end
    if _extractor_disabled(graph, extractor_id, extractor_version, extraction_config_id)
      raise "extractor is disabled: #{extractor_id}@#{extractor_version}"
    end

    extractor = Extractors.get_extractor(extractor_id, extractor_version)
    drafts = extractor.extract(content, normalized_metadata, settings.max_candidates_per_evidence, settings.max_candidate_chars)

    record = ExtractionRecord.new(extraction_identity, evidence_obj.id, evidence.evidence_identity, evidence.revision_id, extractor_id, extractor_version, extraction_config_id, evidence.content_hash, evidence.replay_payload_hash, replayed, replay_verified)
    record_obj = graph.add_object("extraction_record", record.to_json)
    graph.add_relation(record_obj.id, evidence_obj.id, "extraction_for")

    candidate_ids = [] of String
    candidate_types = [] of String
    drafts.each_with_index do |draft, ordinal|
      identity = _candidate_identity(evidence, extractor_id, extractor_version, extraction_config_id, draft, ordinal)
      candidate = _create_candidate(graph, evidence_obj, record_obj.id, draft, identity, extractor_id: extractor_id, extractor_version: extractor_version, extraction_config_id: extraction_config_id)
      candidate_ids << candidate.id
      candidate_types << candidate.type
    end
    _patch(graph, record_obj.id, {"candidate_ids" => JSON::Any.new(candidate_ids.map { |candidate_id| JSON::Any.new(candidate_id) }), "candidate_types" => JSON::Any.new(candidate_types.map { |candidate_type| JSON::Any.new(candidate_type) })})
    {"ok" => JSON::Any.new(true), "record" => JSON::Any.new(record_obj.id), "created" => JSON::Any.new(true)}
  end

  # Mark the prior current revision superseded, preserving all other data.
  def self._supersede_prior(graph : Chronicle::GraphProjection, current : Chronicle::GraphObject) : Nil
    current_data = JSON.parse(current.data).as_h
    current_data["status"] = JSON::Any.new("superseded")
    _patch(graph, current.id, current_data)
  end

  # Emit the source.event_ingested domain event for a new evidence revision.
  def self._emit_ingested(graph : Chronicle::GraphProjection, item : AcquiredItem, handoff : AcquiredContent, evidence_obj : Chronicle::GraphObject, identity : String, revision_id : String, revision_number : Int32, content_hash : String, caused_by : String?) : Nil
    _emit_event(graph, "source.event_ingested", {
      "evidence_identity" => JSON::Any.new(identity),
      "evidence_id"       => JSON::Any.new(evidence_obj.id),
      "revision_id"       => JSON::Any.new(revision_id),
      "revision_number"   => JSON::Any.new(revision_number),
      "source_surface_id" => JSON::Any.new(item.source_surface_id),
      "provider_item_id"  => item.provider_item_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
      "source_ref"        => JSON::Any.new(item.source_ref),
      "content_hash"      => JSON::Any.new(content_hash),
      "provider_time"     => item.provider_time.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
      "source_category"   => JSON.parse(handoff.source_category.to_json),
      "connection_path"   => JSON.parse(handoff.connection_path.to_json),
      "importer_id"       => JSON::Any.new(item.importer_id),
      "importer_version"  => JSON::Any.new(item.importer_version),
      "is_fixture"        => JSON::Any.new(handoff.is_fixture?),
      "replay_complete"   => JSON::Any.new(item.replay_mode != Chronicle::Packs::ReplayMode::ReferenceOnly),
      "invalidated"       => JSON::Any.new(false),
    }, caused_by: caused_by)
  end

  # The newest revision for an evidence identity, plus whether re-ingestion
  # of identical content is idempotent (upstream: skip when hashes match).
  def self._current_revision(graph : Chronicle::GraphProjection, identity : String, content_hash : String) : {Chronicle::GraphObject?, Bool}
    revisions = graph.objects(type: "activity_evidence").select { |obj| ActivityEvidence.from_json(obj.data).evidence_identity == identity }
    revisions.sort_by! { |obj| ActivityEvidence.from_json(obj.data).revision_number }
    current = revisions.last?
    idempotent = current ? ActivityEvidence.from_json(current.data).content_hash == content_hash : false
    {current, idempotent}
  end

  # Build the immutable next evidence revision for an acquisition.
  def self._build_evidence(identity : String, revision_number : Int32, acquired_item_id : String, content_obj : Chronicle::GraphObject, item : AcquiredItem, handoff : AcquiredContent, content_hash : String, current : Chronicle::GraphObject?, event_id : String, settings : ActivityNormalizerSettings) : ActivityEvidence
    revision_id = _stable_id("revision", identity, revision_number, content_hash)
    ActivityEvidence.new(
      identity, revision_id, revision_number,
      acquired_item_id, content_obj.id,
      item.source_surface_id, item.dedup_key, item.source_ref,
      content_hash, item.replay_mode,
      item.replay_payload_ref, item.replay_payload_hash,
      item.replay_mode != Chronicle::Packs::ReplayMode::ReferenceOnly, item.media_type, event_id,
      handoff.normalized_content[0, settings.max_normalized_content_chars], handoff.source_category,
      handoff.connection_path, item.importer_id, item.importer_version,
      provider_item_id: item.provider_item_id, source_hash: item.source_hash,
      provider_time: item.provider_time, encoding: settings.encoding, retention_policy: settings.retention_policy,
      normalized_metadata: handoff.normalized_metadata,
      is_fixture: handoff.is_fixture?, supersedes_evidence_id: current.try(&.id),
    )
  end

  # Wire the evidence revision into the acquisition provenance graph.
  def self._link_evidence(graph : Chronicle::GraphProjection, content_obj : Chronicle::GraphObject, acquired_item_id : String, evidence_obj : Chronicle::GraphObject, current : Chronicle::GraphObject?) : Nil
    graph.add_relation(content_obj.id, acquired_item_id, "content_for")
    graph.add_relation(content_obj.id, evidence_obj.id, "normalizes_to")
    graph.add_relation(evidence_obj.id, acquired_item_id, "acquired_from")
    graph.add_relation(evidence_obj.id, current.id, "supersedes") if current
  end

  # Validate one acquisition, own identity/revision, then extract candidates.
  @[Chronicle::Packs::Annotations::Behavior(name: "normalize_acquired_item", on: ["object.created"], where: {"type" => "acquired_item"}, creates: ["activity_evidence", "extraction_record", "memory_candidate", "preference_candidate", "task_candidate", "profile_candidate", "skill_candidate", "eval_candidate", "ingestion_failure"])]
  def normalize_acquired_item(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload)
    acquired_item_id = payload["id"]?.try(&.as_s?)
    return if acquired_item_id.nil?

    item = AcquiredItem.from_json(payload["data"].to_json)
    content_obj = _content_for(graph, acquired_item_id)
    if content_obj.nil?
      record_failure(graph, stage: "normalization", error_code: "missing_acquired_content", message: "acquired_item has no paired acquired_content handoff", source_surface_id: item.source_surface_id, acquired_item_id: acquired_item_id, source_ref: item.source_ref, importer_id: item.importer_id, importer_version: item.importer_version)
      return
    end

    handoff = AcquiredContent.from_json(content_obj.data)
    begin
      # Validate the retained replay payload is available and verifiable for
      # non-reference_only modes (upstream: read_replay_payload at ingestion).
      if item.replay_mode != Chronicle::Packs::ReplayMode::ReferenceOnly
        Replay.read_replay_payload(JSON.parse(item.to_json).as_h, settings)
      end
      content_hash = item.source_hash || item.replay_payload_hash
      identity = _stable_id("evidence", item.source_surface_id, item.dedup_key)
      current, idempotent = _current_revision(graph, identity, content_hash)
      return if idempotent

      revision_number = current ? ActivityEvidence.from_json(current.data).revision_number + 1 : 1
      evidence = _build_evidence(identity, revision_number, acquired_item_id, content_obj, item, handoff, content_hash, current, event.id, settings)

      _supersede_prior(graph, current) if current
      evidence_obj = graph.add_object("activity_evidence", evidence.to_json)
      _link_evidence(graph, content_obj, acquired_item_id, evidence_obj, current)

      # ADR 0026 step 3: the direct evidence→candidate write path is disabled;
      # extraction runs on the shared annotation layer. The legacy path stays
      # available only as an explicit opt-in for rollback.
      if settings.legacy_extraction_enabled?
        run_extraction(graph, evidence_obj, handoff.normalized_content[0, settings.max_normalized_content_chars], handoff.normalized_metadata, settings, settings.default_extractor_id, settings.default_extractor_version, settings.default_extraction_config_id)
      end

      _emit_ingested(graph, item, handoff, evidence_obj, identity, evidence.revision_id, revision_number, content_hash, event.id) if settings.emit_custom_events?
    rescue ex
      record_failure(graph, stage: "normalization", error_code: "normalization_failed", message: "#{ex.class}: #{ex}", source_surface_id: item.source_surface_id, acquired_item_id: acquired_item_id, source_ref: item.source_ref, importer_id: item.importer_id, importer_version: item.importer_version)
    end
  end

  # Emit the provider-stable cursor state for observational consumers.
  def self._emit_cursor_event(graph : Chronicle::GraphProjection, cursor : Chronicle::GraphObject, caused_by : String?) : Nil
    cursor_data = JSON.parse(cursor.data).as_h
    _emit_event(graph, "source.cursor_advanced", {
      "cursor_id"           => JSON::Any.new(cursor.id),
      "source_surface_id"   => cursor_data["source_surface_id"]? || JSON::Any.new(nil),
      "oldest_ingested_ref" => cursor_data["oldest_ingested_ref"]? || JSON::Any.new(nil),
      "newest_ingested_ref" => cursor_data["newest_ingested_ref"]? || JSON::Any.new(nil),
      "watermark_ref"       => cursor_data["watermark_ref"]? || JSON::Any.new(nil),
      "cursor_version"      => cursor_data["cursor_version"]? || JSON::Any.new(1),
    }, caused_by: caused_by)
  end

  # Publish provider-stable cursor state on cursor creation.
  @[Chronicle::Packs::Annotations::Behavior(name: "publish_cursor_created", on: ["object.created"], where: {"type" => "backfill_cursor"})]
  def publish_cursor_created(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    return if !settings.emit_custom_events?

    payload = JSON.parse(event.payload)
    cursor_id = payload["id"]?.try(&.as_s?)
    return if cursor_id.nil?

    cursor = graph.get_object(cursor_id)
    _emit_cursor_event(graph, cursor, event.id) if cursor
  end

  # Publish each committed cursor advance without interpreting pagination.
  @[Chronicle::Packs::Annotations::Behavior(name: "publish_cursor_patch", on: ["patch.applied"])]
  def publish_cursor_patch(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    return if !settings.emit_custom_events?

    payload = JSON.parse(event.payload)
    target = payload["target"]?.try(&.as_s?)
    return if target.nil?

    cursor = graph.get_object(target)
    if cursor && cursor.type == "backfill_cursor"
      _emit_cursor_event(graph, cursor, event.id)
    end
  end

  # Turn one provider tombstone into explicit, reversible invalidation.
  @[Chronicle::Packs::Annotations::Behavior(name: "fulfill_evidence_invalidation_request", on: ["object.created"], where: {"type" => "evidence_invalidation_request"})]
  def fulfill_evidence_invalidation_request(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ActivityNormalizerSettings) : Nil
    payload = JSON.parse(event.payload)
    request_id = payload["id"]?.try(&.as_s?)
    return if request_id.nil?

    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "proposed"

    source_surface_id = data["source_surface_id"]?.try(&.as_s?)
    return if source_surface_id.nil?

    evidence_identity = data["evidence_identity"]?.try(&.as_s?)
    provider_item_id = data["provider_item_id"]?.try(&.as_s?)
    matches = graph.objects(type: "activity_evidence").select do |obj|
      evidence = ActivityEvidence.from_json(obj.data)
      evidence.source_surface_id == source_surface_id &&
        evidence.status == "current" &&
        ((evidence_identity && evidence.evidence_identity == evidence_identity) ||
          (provider_item_id && evidence.provider_item_id == provider_item_id))
    end
    invalidated = [] of String
    matches.each do |evidence_obj|
      evidence = ActivityEvidence.from_json(evidence_obj.data)
      current_data = JSON.parse(evidence_obj.data).as_h
      current_data["status"] = JSON::Any.new("revoked")
      _patch(graph, evidence_obj.id, current_data)
      _emit_event(graph, "source.evidence_invalidated", {
        "request_id"        => JSON::Any.new(request_id),
        "evidence_id"       => JSON::Any.new(evidence_obj.id),
        "evidence_identity" => JSON::Any.new(evidence.evidence_identity),
        "source_surface_id" => JSON::Any.new(evidence.source_surface_id),
        "provider_item_id"  => evidence.provider_item_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
        "reason"            => data["reason"]? || JSON::Any.new(nil),
      }, caused_by: event.id)
      invalidated << evidence_obj.id
    end
    # A tombstone for an item outside the retained window is an inspectable
    # successful no-op, not an error and not a fabricated evidence object.
    _patch(graph, request_id, {"status" => JSON::Any.new("fulfilled"), "invalidated_evidence_ids" => JSON::Any.new(invalidated.map { |id| JSON::Any.new(id) })})
  end
end

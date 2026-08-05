require "json"

module Chronicle::Packs::Usage
  # Materialize neutral usage facts from connection and normalizer events.
  # Ported from upstream packs/usage/behaviors.py. Object reads use the typed
  # JSON::Serializable structs; only patch merges touch raw JSON.

  # The surface graph object for a surface_id (or nil).
  def self._surface(graph : Chronicle::GraphProjection, surface_id : String) : Chronicle::GraphObject?
    graph.objects(type: "connection_surface").find { |obj| ConnectionSurface.from_json(obj.data).surface_id == surface_id }
  end

  # The gate semantics for a surface (a settling_gate object or settings).
  def self._gate(graph : Chronicle::GraphProjection, surface : Chronicle::GraphObject, settings : UsageSettings) : SettlingGate
    surface_data = ConnectionSurface.from_json(surface.data)
    gate_id = surface_data.gate_id.empty? ? settings.default_gate_id : surface_data.gate_id
    gate_version = surface_data.gate_version < 1 ? settings.default_gate_version : surface_data.gate_version
    gate_obj = graph.objects(type: "settling_gate").find do |obj|
      gate = SettlingGate.from_json(obj.data)
      gate.gate_id == gate_id && gate.gate_version == gate_version
    end
    if gate_obj
      SettlingGate.from_json(gate_obj.data)
    else
      SettlingGate.new(
        _stable_id("settling_gate", settings.default_gate_id, settings.default_gate_version, settings.min_unique_events, settings.min_coverage_days, settings.allow_either?),
        gate_id, gate_version, min_unique_events: settings.min_unique_events,
        min_coverage_days: settings.min_coverage_days, allow_either: settings.allow_either?,
      )
    end
  end

  # Record a fail-closed projection error for an offending event.
  def self._failure(graph : Chronicle::GraphProjection, event : Chronicle::Event, code : String, message : String, payload : Hash(String, JSON::Any)) : Chronicle::GraphObject
    failure = UsageProjectionFailure.new(
      event.id, code, message[0, 1000],
      source_surface_id: payload["source_surface_id"]?.try(&.as_s?) || payload["surface_id"]?.try(&.as_s?),
      evidence_identity: payload["evidence_identity"]?.try(&.as_s?),
    )
    graph.add_object("usage_projection_failure", failure.to_json)
  end

  # Current qualifying (non-invalidated) evidence rows for a surface.
  def self._current_evidence(graph : Chronicle::GraphProjection, surface_id : String) : Array(UsageEvidence)
    graph.objects(type: "usage_evidence").select do |obj|
      evidence = UsageEvidence.from_json(obj.data)
      evidence.source_surface_id == surface_id && evidence.qualifying? && !evidence.invalidated?
    end.map { |obj| UsageEvidence.from_json(obj.data) }
  end

  # Logged observed_at times for a surface from source.clock events.
  def self._clock_times(graph : Chronicle::GraphProjection, surface_id : String) : Array(String)
    graph.events.select { |event| event.type == "source.clock" }.compact_map do |event|
      payload = JSON.parse(event.payload).as_h
      next nil unless payload["surface_id"]?.try(&.as_s?) == surface_id
      next nil if payload["is_fixture"]?.try(&.as_bool?) || false

      payload["observed_at"]?.try(&.as_s?)
    end
  end

  # Merge-append patch: chronicle's patch_object replaces the whole object.
  def self._patch(graph : Chronicle::GraphProjection, target : String, updates : Hash(String, JSON::Any)) : Nil
    current = graph.get_object(target)
    return if current.nil?

    data = JSON.parse(current.data).as_h
    updates.each { |key, value| data[key] = value }
    graph.patch_object(target, JSON::Any.new(data).to_json)
  end

  # Apply a settled state to a surface, minting its first settlement record.
  def self._settle_surface(graph : Chronicle::GraphProjection, event : Chronicle::Event, surface : Chronicle::GraphObject, surface_data : ConnectionSurface, gate : SettlingGate, unique_count : Int32, coverage : Hash(String, JSON::Any), thresholds : Array(String)) : Nil
    surface_id = surface_data.surface_id
    settlement_identity = _stable_id("settlement", surface_id, gate.gate_id, gate.gate_version)
    existing = graph.objects(type: "settlement_record").find { |obj| SettlementRecord.from_json(obj.data).settlement_identity == settlement_identity }
    if existing.nil?
      settled_event = _emit_event(graph, "source.settled", {
        "surface_id"            => JSON::Any.new(surface_id),
        "source_surface_id"     => JSON::Any.new(surface_id),
        "category"              => JSON::Any.new(surface_data.category.wire),
        "gate_id"               => JSON::Any.new(gate.gate_id),
        "gate_version"          => JSON::Any.new(gate.gate_version),
        "unique_evidence_count" => JSON::Any.new(unique_count),
        "coverage_days"         => coverage["coverage_days"]? || JSON::Any.new(0),
        "coverage_start"        => coverage["earliest"]? || JSON::Any.new(nil),
        "coverage_end"          => coverage["latest"]? || JSON::Any.new(nil),
        "passed_thresholds"     => JSON::Any.new(thresholds.map { |threshold| JSON::Any.new(threshold) }),
      })
      record = SettlementRecord.new(
        settlement_identity, surface_id, surface_data.category.wire,
        gate.gate_id, gate.gate_version, unique_count, coverage["coverage_days"]?.try(&.as_i) || 0,
        coverage["earliest"]?.try(&.as_s?), coverage["latest"]?.try(&.as_s?),
        thresholds, settled_event.id, event.id,
      )
      record_obj = graph.add_object("settlement_record", record.to_json)
      graph.add_relation(record_obj.id, surface.id, "settlement_for")
      settled_event_id = settled_event.id
    else
      settled_event_id = data_settled_event_id(existing)
    end
    current = JSON.parse(surface.data).as_h
    current["status"] = JSON::Any.new("settled")
    current["unique_evidence_count"] = JSON::Any.new(unique_count)
    current["first_seen"] = coverage["earliest"]? || JSON::Any.new(nil)
    current["last_seen"] = coverage["latest"]? || JSON::Any.new(nil)
    current["settled_by"] = JSON::Any.new(thresholds.map { |threshold| JSON::Any.new(threshold) })
    current["settled_event_id"] = JSON::Any.new(settled_event_id)
    _patch(graph, surface.id, current)
  end

  # A surface's previous settlement-record event id, if it was settled before.
  def self.data_settled_event_id(record : Chronicle::GraphObject) : String
    data = JSON.parse(record.data)
    data["source_settled_event_id"]?.try(&.as_s?) || record.id
  end

  # Apply a settling/connected/stale state to a surface without settling.
  def self._progress_surface(graph : Chronicle::GraphProjection, event : Chronicle::Event, surface : Chronicle::GraphObject, surface_data : ConnectionSurface, gate : SettlingGate, evidence_rows : Array(UsageEvidence), unique_count : Int32, coverage : Hash(String, JSON::Any)) : Nil
    surface_id = surface_data.surface_id
    settlement_identity = _stable_id("settlement", surface_id, gate.gate_id, gate.gate_version)
    existing = graph.objects(type: "settlement_record").find { |obj| SettlementRecord.from_json(obj.data).settlement_identity == settlement_identity }
    status = if existing
               "stale"
             elsif !evidence_rows.empty?
               if surface_data.status != Chronicle::Packs::SurfaceStatus::Settling
                 _emit_event(graph, "source.settling", {
                   "surface_id"            => JSON::Any.new(surface_id),
                   "category"              => JSON::Any.new(surface_data.category.wire),
                   "gate_id"               => JSON::Any.new(gate.gate_id),
                   "gate_version"          => JSON::Any.new(gate.gate_version),
                   "unique_evidence_count" => JSON::Any.new(unique_count),
                   "coverage_days"         => coverage["coverage_days"]? || JSON::Any.new(0),
                 })
               end
               "settling"
             else
               "connected"
             end
    current = JSON.parse(surface.data).as_h
    current["status"] = JSON::Any.new(status)
    current["unique_evidence_count"] = JSON::Any.new(unique_count)
    current["first_seen"] = coverage["earliest"]? || JSON::Any.new(nil)
    current["last_seen"] = coverage["latest"]? || JSON::Any.new(nil)
    current["settled_by"] = JSON::Any.new([] of JSON::Any)
    _patch(graph, surface.id, current)
  end

  # Evaluate one surface's current gate and settle/patch as needed.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _evaluate_surface gate logic
  def self._evaluate_surface(graph : Chronicle::GraphProjection, event : Chronicle::Event, surface : Chronicle::GraphObject, evidence_rows : Array(UsageEvidence), settings : UsageSettings) : Nil
    surface_data = ConnectionSurface.from_json(surface.data)
    gate = _gate(graph, surface, settings)
    unique_count = evidence_rows.map(&.evidence_identity).to_set.size
    times = evidence_rows.compact_map(&.provider_time)
    if !evidence_rows.empty? && surface_data.acquisition_mode == "live"
      times.concat(_clock_times(graph, surface_data.surface_id))
    end
    coverage = _coverage_from_times(times)
    volume_passed = unique_count >= gate.min_unique_events
    coverage_passed = (coverage["coverage_days"]?.try(&.as_i) || 0) >= gate.min_coverage_days
    passed = gate.allow_either? ? (volume_passed || coverage_passed) : (volume_passed && coverage_passed)
    thresholds = [] of String
    thresholds << "volume" if volume_passed
    thresholds << "coverage" if coverage_passed

    if surface_data.status.in?(Chronicle::Packs::SurfaceStatus::Stale, Chronicle::Packs::SurfaceStatus::Revoked, Chronicle::Packs::SurfaceStatus::Failed) && event.type != "source.connected"
      current = JSON.parse(surface.data).as_h
      current["unique_evidence_count"] = JSON::Any.new(unique_count)
      current["first_seen"] = coverage["earliest"]? || JSON::Any.new(nil)
      current["last_seen"] = coverage["latest"]? || JSON::Any.new(nil)
      _patch(graph, surface.id, current)
      return
    end

    if passed
      _settle_surface(graph, event, surface, surface_data, gate, unique_count, coverage, thresholds)
      return
    end
    _progress_surface(graph, event, surface, surface_data, gate, evidence_rows, unique_count, coverage)
  end

  # Connector packs request; Usage alone owns surface identity and events.
  @[Chronicle::Packs::Annotations::Behavior(name: "fulfill_source_connection_request", on: ["object.created"], where: {"type" => "source_connection_request"}, creates: ["connection_surface", "settling_gate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream request-fulfillment
  def fulfill_source_connection_request(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : UsageSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    request_id = payload["id"]?.try(&.as_s?)
    return if request_id.nil?

    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "proposed"
    begin
      result = connect_surface_fn(
        graph,
        data["surface_id"]?.try(&.as_s?) || "", data["category"]?.try(&.as_s?) || "",
        provider: data["provider"]?.try(&.as_h) || {} of String => JSON::Any,
        path: data["path"]?.try(&.as_s?) || "",
        privacy_scope: data["privacy_scope"]?.try(&.as_s?) || "account",
        adapter: data["adapter"]?.try(&.as_s?),
        acquisition_mode: data["acquisition_mode"]?.try(&.as_s?) || "backfill",
        metadata: data["metadata"]?.try(&.as_h) || {} of String => JSON::Any,
        settings: settings,
      )
      _patch_request(graph, request_id, {"status" => JSON::Any.new("fulfilled"), "surface_object_id" => result["surface_object_id"]? || JSON::Any.new(nil)})
    rescue ex
      _patch_request(graph, request_id, {"status" => JSON::Any.new("failed"), "error" => JSON::Any.new("#{ex.class}: #{ex}"[0, 500])})
    end
  end

  # Merge-patch a source_connection_request object.
  def self._patch_request(graph : Chronicle::GraphProjection, request_id : String, updates : Hash(String, JSON::Any)) : Nil
    request_obj = graph.get_object(request_id)
    return if request_obj.nil?

    current = JSON.parse(request_obj.data).as_h
    updates.each { |key, value| current[key] = value }
    graph.patch_object(request_id, JSON::Any.new(current).to_json)
  end

  # Validate the required evidence identity fields in an ingested payload.
  def self._missing_identity_fields(payload : Hash(String, JSON::Any)) : Array(String)
    required = {
      "evidence_identity" => payload["evidence_identity"]?,
      "evidence_id"       => payload["evidence_id"]?,
      "revision_id"       => payload["revision_id"]?,
      "source_ref"        => payload["source_ref"]?,
      "importer_id"       => payload["importer_id"]?,
      "importer_version"  => payload["importer_version"]?,
    }
    required.select { |_name, value| value.nil? }.keys.sort!
  end

  # Build the typed usage_evidence row for one ingested event.
  def self._build_usage_evidence(payload : Hash(String, JSON::Any), surface_id : String, category : String, existing : Chronicle::GraphObject?, event : Chronicle::Event, qualifying : Bool) : UsageEvidence
    prior = existing ? UsageEvidence.from_json(existing.data) : nil
    UsageEvidence.new(
      payload["evidence_identity"].as_s, payload["evidence_id"].as_s, payload["revision_id"].as_s,
      payload["revision_number"]?.try(&.as_i) || 1, surface_id, category,
      payload["connection_path"]?.try(&.as_s?) || "", payload["source_ref"].as_s,
      payload["importer_id"].as_s, payload["importer_version"].as_s,
      prior ? prior.first_ingested_event_id : event.id, event.id,
      provider_time: payload["provider_time"]?.try(&.as_s?),
      is_fixture: payload["is_fixture"]?.try(&.as_bool?) || false,
      qualifying: qualifying,
      invalidated: payload["invalidated"]?.try(&.as_bool?) || false,
      revision_count: prior ? prior.revision_count + (prior.revision_id != payload["revision_id"].as_s ? 1 : 0) : 1,
    )
  end

  # Index one normalizer identity and evaluate its surface's current gate.
  @[Chronicle::Packs::Annotations::Behavior(name: "observe_normalized_evidence", on: ["source.event_ingested"], creates: ["usage_evidence", "settlement_record", "usage_projection_failure"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream evidence indexer guards
  def observe_normalized_evidence(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : UsageSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload).as_h
    surface_id = payload["source_surface_id"]?.try(&.as_s?) || ""
    surface = _surface(graph, surface_id)
    if surface.nil?
      _failure(graph, event, code: "unknown_surface", message: "evidence references unknown surface #{surface_id.inspect}", payload: payload)
      return
    end
    begin
      category = validate_source_category(payload["source_category"]?.try(&.as_s?) || "")
    rescue ex : ArgumentError
      _failure(graph, event, code: "unknown_category", message: ex.message || "", payload: payload)
      return
    end
    missing = _missing_identity_fields(payload)
    unless missing.empty?
      _failure(graph, event, code: "incomplete_evidence_identity", message: "qualifying evidence metadata missing: #{missing.join(", ")}", payload: payload)
      return
    end
    surface_data = ConnectionSurface.from_json(surface.data)
    if category != surface_data.category.wire || payload["connection_path"]?.try(&.as_s?) != surface_data.path.wire
      _failure(graph, event, code: "surface_metadata_mismatch", message: "evidence category/path does not match its connection surface", payload: payload)
      return
    end

    identity = payload["evidence_identity"].as_s
    existing = graph.objects(type: "usage_evidence").find do |obj|
      evidence = UsageEvidence.from_json(obj.data)
      evidence.evidence_identity == identity && evidence.source_surface_id == surface_id
    end
    qualifying = !(payload["invalidated"]?.try(&.as_bool?) || false) &&
                 !(payload["is_fixture"]?.try(&.as_bool?) || false) &&
                 !surface_data.is_fixture?
    row = _build_usage_evidence(payload, surface_id, category, existing, event, qualifying)

    if existing.nil?
      index = graph.add_object("usage_evidence", row.to_json)
      graph.add_relation(index.id, surface.id, "evidence_on_surface")
    else
      _patch(graph, existing.id, JSON.parse(row.to_json).as_h)
    end

    current = _current_evidence(graph, surface_id).select { |evidence| evidence.evidence_identity != identity }
    current << row if qualifying
    surface_update = JSON.parse(surface.data).as_h
    surface_update["events_seen"] = JSON::Any.new((surface_update["events_seen"]?.try(&.as_i) || 0) + 1)
    _patch(graph, surface.id, surface_update)
    _evaluate_surface(graph, event, surface, current, settings: settings)
  end

  # Re-evaluate existing evidence on reconnect without duplicating settlement.
  @[Chronicle::Packs::Annotations::Behavior(name: "observe_surface_connection", on: ["source.connected"], creates: ["settlement_record"])]
  def observe_surface_connection(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : UsageSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    surface_id = payload["surface_id"]?.try(&.as_s?) || ""
    surface = _surface(graph, surface_id)
    return if surface.nil?

    _evaluate_surface(graph, event, surface, _current_evidence(graph, surface_id), settings: settings)
  end

  # Project provider-stable cursor facts without implementing pagination.
  @[Chronicle::Packs::Annotations::Behavior(name: "observe_cursor_progress", on: ["source.cursor_advanced"], creates: ["usage_projection_failure"])]
  def observe_cursor_progress(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : UsageSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    surface_id = payload["source_surface_id"]?.try(&.as_s?) || payload["surface_id"]?.try(&.as_s?) || ""
    surface = _surface(graph, surface_id)
    if surface.nil?
      _failure(graph, event, code: "unknown_cursor_surface", message: "cursor references unknown surface #{surface_id.inspect}", payload: payload)
      return
    end
    current = JSON.parse(surface.data).as_h
    current["cursor_state"] = JSON::Any.new({
      "oldest_ingested_ref" => payload["oldest_ingested_ref"]? || JSON::Any.new(nil),
      "newest_ingested_ref" => payload["newest_ingested_ref"]? || JSON::Any.new(nil),
      "watermark_ref"       => payload["watermark_ref"]? || JSON::Any.new(nil),
      "cursor_version"      => payload["cursor_version"]? || JSON::Any.new(1),
    })
    _patch(graph, surface.id, current)
  end

  # Re-evaluate a live surface using only its logged clock facts.
  @[Chronicle::Packs::Annotations::Behavior(name: "observe_source_clock", on: ["source.clock"], creates: ["settlement_record"])]
  def observe_source_clock(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : UsageSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    surface_id = payload["surface_id"]?.try(&.as_s?) || ""
    surface = _surface(graph, surface_id)
    return if surface.nil? || ConnectionSurface.from_json(surface.data).acquisition_mode != "live"

    _evaluate_surface(graph, event, surface, _current_evidence(graph, surface_id), settings: settings)
  end

  # Remove one logical identity from current qualification without erasing it.
  @[Chronicle::Packs::Annotations::Behavior(name: "observe_evidence_invalidation", on: ["source.evidence_invalidated", "source.event_invalidated"])]
  def observe_evidence_invalidation(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : UsageSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    surface_id = payload["source_surface_id"]?.try(&.as_s?) || payload["surface_id"]?.try(&.as_s?) || ""
    identity = payload["evidence_identity"]?.try(&.as_s?) || ""
    index = graph.objects(type: "usage_evidence").find do |obj|
      evidence = UsageEvidence.from_json(obj.data)
      evidence.source_surface_id == surface_id && evidence.evidence_identity == identity
    end
    surface = _surface(graph, surface_id)
    return if index.nil? || surface.nil?

    current = JSON.parse(index.data).as_h
    current["invalidated"] = JSON::Any.new(true)
    current["qualifying"] = JSON::Any.new(false)
    _patch(graph, index.id, current)
    remaining = _current_evidence(graph, surface_id).select { |evidence| evidence.evidence_identity != identity }
    _evaluate_surface(graph, event, surface, remaining, settings: settings)
  end
end

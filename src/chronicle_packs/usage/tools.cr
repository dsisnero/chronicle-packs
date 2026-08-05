require "json"
require "digest"
require "time"

module Chronicle::Packs::Usage
  # Graph-visible mutation and explicit-horizon query capabilities for Usage.
  # Ported from upstream packs/usage/tools.py. The event log is the only
  # projection input; queries require an explicit horizon event id.

  class_property event_seq : UInt64 = 0
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module Categories
    SOURCE_CATEGORIES           = ["communication", "rhythm", "ai_activity", "code_work", "local_knowledge", "tool_automation", "outcome_evaluation"]
    SOURCE_CATEGORY_SET         = Set(String).new(SOURCE_CATEGORIES)
    CONNECTION_PATHS            = Set(String).new(["export", "mcp", "composio", "native", "local", "pack", "manual"])
    PRIVACY_SCOPES              = Set(String).new(["source", "account", "folder", "label", "workspace"])
    SURFACE_STATUSES            = Set(String).new(["connected", "settling", "settled", "stale", "revoked", "failed"])
    EXPLICIT_LIFECYCLE_STATUSES = Set(String).new(["connected", "stale", "revoked", "failed"])
    LIVE_CONNECTION_PATHS       = Set(String).new(["mcp", "composio", "native", "pack"])
    DEFAULT_GATE                = {
      "gate_id"           => JSON::Any.new("usage.category.default"),
      "gate_version"      => JSON::Any.new(1),
      "min_unique_events" => JSON::Any.new(25),
      "min_coverage_days" => JSON::Any.new(3),
      "allow_either"      => JSON::Any.new(true),
    }
    TERMINAL_OUTCOMES = Set(String).new(["outcome.helped", "outcome.hurt", "outcome.neutral"])
  end

  # Return a canonical category or fail instead of inventing a fallback.
  # Format a Time into the canonical UTC ISO-8601 string used in the graph.
  def self._fmt_iso8601(value : Time) : String
    value.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  def self.validate_source_category(category : String) : String
    raise ArgumentError.new("unknown source category #{category.inspect}; expected one of #{Categories::SOURCE_CATEGORIES.join(", ")}") unless Categories::SOURCE_CATEGORY_SET.includes?(category)
    category
  end

  def self._stable_id(prefix : String, *parts) : String
    encoded = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(encoded)}"
  end

  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any), caused_by : String? = nil, actor : String = "usage") : Chronicle::Event
    seq = (self.event_seq += 1)
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{event_type.gsub('.', "_")}_#{seq}",
      type: event_type, actor: actor, caused_by: caused_by,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
  end

  # Canonical JSON for idempotency comparisons.
  def self._canonical_json(value : JSON::Any) : String
    value.to_json
  end

  # Parse an ISO 8601 timestamp into UTC, or nil.
  def self._parse_timestamp(value : String?) : Time?
    return nil if value.nil? || value.strip.empty?
    Time.parse_iso8601(value.strip) rescue nil
  end

  def self._require_timestamp(value : String, field_name : String) : String
    parsed = _parse_timestamp(value)
    raise ArgumentError.new("#{field_name} must be an ISO 8601 timestamp") if parsed.nil?
    parsed.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  def self._surface_logical_id(data : Hash(String, JSON::Any)) : String?
    value = data["id"]? || data["surface_id"]?
    value.try(&.as_s?)
  end

  def self._find_surface(graph : Chronicle::GraphProjection, surface_id : String, reader : Chronicle::GraphProjection? = nil) : Chronicle::GraphObject?
    matches = (reader || graph).objects(type: "connection_surface").select { |obj| _surface_logical_id(JSON.parse(obj.data).as_h) == surface_id }
    raise Chronicle::Packs::PackError.new("multiple connection_surface objects claim id #{surface_id.inspect}") if matches.size > 1
    matches.first?
  end

  def self._find_gate(graph : Chronicle::GraphProjection, gate_id : String, gate_version : Int32, reader : Chronicle::GraphProjection? = nil) : Chronicle::GraphObject?
    matches = (reader || graph).objects(type: "settling_gate").select do |obj|
      data = JSON.parse(obj.data)
      data["gate_id"]?.try(&.as_s?) == gate_id && data["gate_version"]?.try(&.as_i?) == gate_version
    end
    raise Chronicle::Packs::PackError.new("duplicate settling gate #{gate_id}@#{gate_version}") if matches.size > 1
    matches.first?
  end

  # Create the immutable default gate once and reject semantic mutation.
  def self.ensure_default_gate_fn(graph : Chronicle::GraphProjection, settings : UsageSettings = UsageSettings.new, reader : Chronicle::GraphProjection? = nil) : Chronicle::GraphObject
    definition = JSON.build do |json|
      json.object do
        json.field "definition_identity", _stable_id("settling_gate", settings.default_gate_id, settings.default_gate_version, settings.min_unique_events, settings.min_coverage_days, settings.allow_either?)
        json.field "gate_id", settings.default_gate_id
        json.field "gate_version", settings.default_gate_version
        json.field "category", JSON::Any.new(nil)
        json.field "min_unique_events", settings.min_unique_events
        json.field "min_coverage_days", settings.min_coverage_days
        json.field "allow_either", settings.allow_either?
        json.field "active", true
      end
    end
    definition_hash = JSON.parse(definition).as_h
    default_hash = Categories::DEFAULT_GATE
    if definition_hash["gate_id"]?.try(&.as_s?) == default_hash["gate_id"].as_s && definition_hash["gate_version"]?.try(&.as_i?) == default_hash["gate_version"].as_i
      mutated = default_hash.any? { |key, value| definition_hash[key]?.try(&.raw) != value.raw && key != "gate_id" && key != "gate_version" }
      raise ArgumentError.new("usage.category.default@1 semantics are immutable; use a new gate version") if mutated
    end
    existing = _find_gate(graph, settings.default_gate_id, settings.default_gate_version, reader: reader)
    if existing
      actual = JSON.parse(existing.data).as_h
      semantic = %w(gate_id gate_version min_unique_events min_coverage_days allow_either active)
      mismatch = semantic.any? { |key| actual[key]? != definition_hash[key]? }
      raise ArgumentError.new("settling gate #{definition_hash["gate_id"]}@#{definition_hash["gate_version"]} already exists with different semantics; create a new gate version") if mismatch
      return existing
    end
    graph.add_object("settling_gate", definition)
  end

  def self._cursor_default : Hash(String, JSON::Any)
    {"oldest_ingested_ref" => JSON::Any.new(nil), "newest_ingested_ref" => JSON::Any.new(nil), "watermark_ref" => JSON::Any.new(nil), "cursor_version" => JSON::Any.new(1)}
  end

  # Create or reconnect exactly one logical source surface.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream connect_surface_fn (create vs reconnect)
  def self.connect_surface_fn(graph : Chronicle::GraphProjection, surface_id : String, category : String, provider : Hash(String, JSON::Any) = {} of String => JSON::Any, path : String = "native", privacy_scope : String = "source", adapter : String? = nil, acquisition_mode : String = "snapshot", cursor_state : Hash(String, JSON::Any)? = nil, is_fixture : Bool = false, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any, settings : UsageSettings = UsageSettings.new, reader : Chronicle::GraphProjection? = nil) : Hash(String, JSON::Any)
    raise ArgumentError.new("surface_id is required") if surface_id.empty?
    category = validate_source_category(category)
    raise ArgumentError.new("unknown connection path #{path.inspect}") unless Categories::CONNECTION_PATHS.includes?(path)
    raise ArgumentError.new("unknown privacy scope #{privacy_scope.inspect}") unless Categories::PRIVACY_SCOPES.includes?(privacy_scope)
    raise ArgumentError.new("unknown acquisition mode #{acquisition_mode.inspect}") unless acquisition_mode.in?({"snapshot", "backfill", "live"})
    gate = ensure_default_gate_fn(graph, settings: settings, reader: reader)
    gate_data = JSON.parse(gate.data).as_h

    requested = {
      "surface_id"            => JSON::Any.new(surface_id),
      "category"              => JSON::Any.new(category),
      "provider"              => JSON::Any.new(provider),
      "path"                  => JSON::Any.new(path),
      "adapter"               => adapter.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
      "acquisition_mode"      => JSON::Any.new(acquisition_mode),
      "status"                => JSON::Any.new("connected"),
      "privacy_scope"         => JSON::Any.new(privacy_scope),
      "cursor_state"          => JSON::Any.new(cursor_state || _cursor_default),
      "is_fixture"            => JSON::Any.new(is_fixture),
      "events_seen"           => JSON::Any.new(0),
      "unique_evidence_count" => JSON::Any.new(0),
      "first_seen"            => JSON::Any.new(nil),
      "last_seen"             => JSON::Any.new(nil),
      "gate_id"               => gate_data["gate_id"]? || JSON::Any.new(nil),
      "gate_version"          => gate_data["gate_version"]? || JSON::Any.new(nil),
      "settled_by"            => JSON::Any.new([] of JSON::Any),
      "settled_event_id"      => JSON::Any.new(nil),
      "metadata"              => JSON::Any.new(metadata),
    }

    existing = _find_surface(graph, surface_id, reader: reader)
    if existing.nil?
      surface = graph.add_object("connection_surface", JSON::Any.new(requested).to_json)
      created = true
    else
      current = JSON.parse(existing.data).as_h
      %w(category path privacy_scope acquisition_mode).each do |immutable|
        if current[immutable]? != requested[immutable]?
          raise Chronicle::Packs::PackError.new("surface #{surface_id.inspect} already has #{immutable}=#{current[immutable]}; create a new surface identity")
        end
      end
      updates = {"status" => JSON::Any.new("connected")}
      updates["provider"] = JSON::Any.new(provider) unless provider.empty?
      if !adapter.nil?
        updates["adapter"] = JSON::Any.new(adapter)
      end
      updates["metadata"] = JSON::Any.new(metadata) unless metadata.empty?
      if is_fixture != (current["is_fixture"]?.try(&.as_bool?) || false)
        updates["is_fixture"] = JSON::Any.new(is_fixture)
      end
      if cursor_state
        updates["cursor_state"] = JSON::Any.new(cursor_state)
      end
      current_data = JSON.parse(existing.data).as_h
      updates.each { |key, value| current_data[key] = value }
      graph.patch_object(existing.id, JSON::Any.new(current_data).to_json)
      surface = graph.get_object(existing.id) || existing
      created = false
    end

    surface_data = JSON.parse(surface.data).as_h
    event = _emit_event(graph, "source.connected", {
      "surface_id"            => JSON::Any.new(surface_id),
      "surface_object_id"     => JSON::Any.new(surface.id),
      "category"              => surface_data["category"]? || JSON::Any.new(nil),
      "provider"              => surface_data["provider"]? || JSON::Any.new({} of String => JSON::Any),
      "path"                  => surface_data["path"]? || JSON::Any.new(nil),
      "adapter"               => surface_data["adapter"]? || JSON::Any.new(nil),
      "acquisition_mode"      => surface_data["acquisition_mode"]? || JSON::Any.new("snapshot"),
      "status"                => JSON::Any.new("connected"),
      "privacy_scope"         => surface_data["privacy_scope"]? || JSON::Any.new(nil),
      "cursor_state"          => surface_data["cursor_state"]? || JSON::Any.new(_cursor_default),
      "events_seen"           => surface_data["events_seen"]? || JSON::Any.new(0),
      "unique_evidence_count" => surface_data["unique_evidence_count"]? || JSON::Any.new(0),
      "first_seen"            => surface_data["first_seen"]? || JSON::Any.new(nil),
      "last_seen"             => surface_data["last_seen"]? || JSON::Any.new(nil),
      "is_fixture"            => surface_data["is_fixture"]? || JSON::Any.new(false),
      "metadata"              => surface_data["metadata"]? || JSON::Any.new({} of String => JSON::Any),
      "gate_id"               => gate_data["gate_id"]? || JSON::Any.new(nil),
      "gate_version"          => gate_data["gate_version"]? || JSON::Any.new(nil),
      "settled_by"            => surface_data["settled_by"]? || JSON::Any.new([] of JSON::Any),
      "settled_event_id"      => surface_data["settled_event_id"]? || JSON::Any.new(nil),
      "reconnect"             => JSON::Any.new(!created),
    })
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "surface_id" => JSON::Any.new(surface_id), "surface_object_id" => JSON::Any.new(surface.id), "connection_event_id" => JSON::Any.new(event.id), "gate_id" => gate_data["gate_id"]? || JSON::Any.new(nil), "gate_version" => gate_data["gate_version"]? || JSON::Any.new(nil)}
  end

  # Record an explicit lifecycle fact; computed states cannot be forced.
  def self.set_surface_status_fn(graph : Chronicle::GraphProjection, surface_id : String, status : String, reason : String = "", metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    raise ArgumentError.new("explicit lifecycle status must be connected, stale, revoked, or failed") unless Categories::EXPLICIT_LIFECYCLE_STATUSES.includes?(status)
    surface = _find_surface(graph, surface_id)
    raise ArgumentError.new("unknown connection surface #{surface_id.inspect}") if surface.nil?
    surface_data = JSON.parse(surface.data).as_h
    previous = surface_data["status"]?
    event = _emit_event(graph, "source.lifecycle_changed", {
      "surface_id"        => JSON::Any.new(surface_id),
      "surface_object_id" => JSON::Any.new(surface.id),
      "category"          => surface_data["category"]? || JSON::Any.new(nil),
      "path"              => surface_data["path"]? || JSON::Any.new(nil),
      "previous_status"   => previous || JSON::Any.new(nil),
      "status"            => JSON::Any.new(status),
      "reason"            => JSON::Any.new(reason),
      "metadata"          => JSON::Any.new(metadata),
    })
    current_data = JSON.parse(surface.data).as_h
    current_data["status"] = JSON::Any.new(status)
    graph.patch_object(surface.id, JSON::Any.new(current_data).to_json)
    {"ok" => JSON::Any.new(true), "surface_id" => JSON::Any.new(surface_id), "status" => JSON::Any.new(status), "event_id" => JSON::Any.new(event.id)}
  end

  # Append an idempotent logged clock input for a live source surface.
  def self.record_source_clock_fn(graph : Chronicle::GraphProjection, surface_id : String, observed_at : String, clock_id : String? = nil, is_fixture : Bool = false, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    surface = _find_surface(graph, surface_id)
    raise ArgumentError.new("unknown connection surface #{surface_id.inspect}") if surface.nil?
    surface_data = JSON.parse(surface.data).as_h
    raise ArgumentError.new("source.clock is valid only for acquisition_mode='live'") unless surface_data["acquisition_mode"]?.try(&.as_s?) == "live"
    canonical_time = _require_timestamp(observed_at, "observed_at")
    identity = clock_id || _stable_id("source_clock", surface_id, canonical_time)
    existing = graph.events.select { |event| event.type == "source.clock" && (JSON.parse(event.payload)["clock_id"]?.try(&.as_s?) == identity) }
    unless existing.empty?
      prior = existing.last
      prior_payload = JSON.parse(prior.payload).as_h
      if prior_payload["surface_id"]?.try(&.as_s?) != surface_id || prior_payload["observed_at"]?.try(&.as_s?) != canonical_time
        raise ArgumentError.new("clock_id #{identity.inspect} already records a different fact")
      end
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "clock_id" => JSON::Any.new(identity), "event_id" => JSON::Any.new(prior.id)}
    end
    event = _emit_event(graph, "source.clock", {
      "clock_id"    => JSON::Any.new(identity),
      "surface_id"  => JSON::Any.new(surface_id),
      "category"    => surface_data["category"]? || JSON::Any.new(nil),
      "observed_at" => JSON::Any.new(canonical_time),
      "is_fixture"  => JSON::Any.new(is_fixture),
      "metadata"    => JSON::Any.new(metadata),
    })
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "clock_id" => JSON::Any.new(identity), "event_id" => JSON::Any.new(event.id)}
  end

  # Record one idempotent neutral interaction fact.
  def self.record_usage_fn(graph : Chronicle::GraphProjection, usage_identity : String, surface_id : String, interaction_type : String, evidence_identity : String? = nil, provider_time : String? = nil, count : Int32 = 1, is_fixture : Bool = false, provenance : Hash(String, JSON::Any) = {} of String => JSON::Any, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    raise ArgumentError.new("usage_identity and interaction_type are required") if usage_identity.empty? || interaction_type.empty?
    raise ArgumentError.new("count must be positive") if count < 1
    surface = _find_surface(graph, surface_id)
    raise ArgumentError.new("unknown connection surface #{surface_id.inspect}") if surface.nil?
    category = validate_source_category(JSON.parse(surface.data)["category"]?.try(&.as_s?) || "")
    canonical_time = provider_time ? _require_timestamp(provider_time, "provider_time") : nil
    record = UsageRecord.new(
      usage_identity, surface_id, category, interaction_type,
      evidence_identity: evidence_identity, provider_time: canonical_time, count: count,
      is_fixture: is_fixture, source_provenance: provenance, metadata: metadata,
    )
    requested = JSON.parse(record.to_json).as_h
    matches = graph.objects(type: "usage_record").select { |obj| JSON.parse(obj.data)["usage_identity"]?.try(&.as_s?) == usage_identity }
    raise Chronicle::Packs::PackError.new("duplicate usage_record identity #{usage_identity.inspect}") if matches.size > 1
    unless matches.empty?
      existing = matches.first
      if JSON.parse(existing.data) != requested
        raise ArgumentError.new("usage_identity #{usage_identity.inspect} already records a different fact")
      end
      event = graph.events.find { |item| item.type == "usage.recorded" && (JSON.parse(item.payload)["usage_identity"]?.try(&.as_s?) == usage_identity) }
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "usage_record_id" => JSON::Any.new(existing.id), "event_id" => event ? JSON::Any.new(event.id) : JSON::Any.new(nil)}
    end
    record_obj = graph.add_object("usage_record", record.to_json)
    graph.add_relation(record_obj.id, surface.id, "usage_on_surface")
    event_payload = requested.dup
    event_payload["usage_record_id"] = JSON::Any.new(record_obj.id)
    event = _emit_event(graph, "usage.recorded", event_payload)
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "usage_record_id" => JSON::Any.new(record_obj.id), "event_id" => JSON::Any.new(event.id)}
  end

  # Events through (inclusive of) the required horizon.
  def self._events_through(graph : Chronicle::GraphProjection, event_horizon_event_id : String) : Array(Chronicle::Event)
    raise ArgumentError.new("event_horizon_event_id is required") if event_horizon_event_id.empty?
    events = graph.events
    indexes = [] of Int32
    events.each_with_index { |event, index| indexes << index if event.id == event_horizon_event_id }
    raise ArgumentError.new("unknown event horizon #{event_horizon_event_id.inspect}") if indexes.empty?
    raise ArgumentError.new("event horizon id is ambiguous: #{event_horizon_event_id.inspect}") if indexes.size > 1
    events[0..indexes.first]
  end

  def self._coverage_from_times(values : Enumerable(String?)) : Hash(String, JSON::Any)
    parsed = values.compact_map { |value| _parse_timestamp(value) }.sort!
    if parsed.empty?
      return {"earliest" => JSON::Any.new(nil), "latest" => JSON::Any.new(nil), "coverage_days" => JSON::Any.new(0)}
    end
    days = ((parsed.last.to_unix - parsed.first.to_unix) // 86_400).to_i
    {"earliest" => JSON::Any.new(parsed.first.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ")), "latest" => JSON::Any.new(parsed.last.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ")), "coverage_days" => JSON::Any.new(days)}
  end

  def self._empty_counter : Hash(String, JSON::Any)
    {"total" => JSON::Any.new(0), "by_kind" => JSON::Any.new({} of String => JSON::Any)}
  end

  def self._increment_counter(counter : Hash(String, JSON::Any), kind : String, amount : Int32 = 1) : Nil
    counter["total"] = JSON::Any.new((counter["total"]?.try(&.as_i) || 0) + amount)
    by_kind = counter["by_kind"]?.try(&.as_h) || {} of String => JSON::Any
    by_kind[kind] = JSON::Any.new((by_kind[kind]?.try(&.as_i) || 0) + amount)
    counter["by_kind"] = JSON::Any.new(by_kind)
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream 10-field qualifying predicate
  def self._qualifying_evidence(payload : Hash(String, JSON::Any), surface : Hash(String, JSON::Any)) : Bool
    sid = surface["surface_id"]?.try(&.as_s?) || surface["id"]?.try(&.as_s?) || ""
    !payload["evidence_identity"]?.try(&.as_s?).nil? &&
      payload["source_surface_id"]?.try(&.as_s?) == sid &&
      !payload["source_ref"]?.try(&.as_s?).nil? &&
      payload["source_category"]?.try(&.as_s?) == surface["category"]?.try(&.as_s?) &&
      payload["connection_path"]?.try(&.as_s?) == surface["path"]?.try(&.as_s?) &&
      !payload["importer_id"]?.try(&.as_s?).nil? &&
      !payload["importer_version"]?.try(&.as_s?).nil? &&
      !(payload["invalidated"]?.try(&.as_bool?) || false) &&
      !(payload["is_fixture"]?.try(&.as_bool?) || false) &&
      !(surface["is_fixture"]?.try(&.as_bool?) || false)
  end

  # ---- projections ---------------------------------------------------------

  # Apply one object.created event to the projection state.
  def self._apply_created_event(payload : Hash(String, JSON::Any), gates : Hash({String, Int32}, Hash(String, JSON::Any)), usage_records : Hash(String, Hash(String, JSON::Any))) : Nil
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    case payload["type"]?.try(&.as_s?)
    when "settling_gate"
      gate_id = data["gate_id"]?.try(&.as_s?)
      gate_version = data["gate_version"]?.try(&.as_i?)
      if gate_id && gate_version
        key = {gate_id, gate_version}
        if gates.has_key?(key)
          semantic = %w(gate_id gate_version min_unique_events min_coverage_days allow_either)
          prior = gates[key]
          mismatch = semantic.any? { |name| prior[name]?.try(&.raw) != data[name]?.try(&.raw) }
          raise Chronicle::Packs::PackError.new("gate #{gate_id}@#{gate_version} changed semantics") if mismatch
        end
        gates[key] = data
      end
    when "usage_record"
      usage_id = data["usage_identity"]?.try(&.as_s?)
      if usage_id
        row = data.dup
        row["event_id"] = JSON::Any.new(payload["event_id"]?.try(&.as_s?) || "")
        usage_records[usage_id] = row unless usage_records.has_key?(usage_id)
      end
    end
  end

  # Apply surface connection / lifecycle / cursor events to the projection.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream surface event replay branches
  def self._apply_surface_event(event_type : String, payload : Hash(String, JSON::Any), ordinal : Int32, surfaces : Hash(String, Hash(String, JSON::Any)), lifecycle : Hash(String, Hash(String, JSON::Any))) : Nil
    case event_type
    when "source.connected"
      surface = _surface_from_connected(payload)
      sid = surface["id"].as_s
      prior = surfaces[sid]? || {} of String => JSON::Any
      merged = prior.dup
      surface.each { |field, value| merged[field] = value }
      surfaces[sid] = merged
      lifecycle[sid] = {"status" => JSON::Any.new("connected"), "reason" => JSON::Any.new(""), "event_id" => JSON::Any.new(payload["event_id"]?.try(&.as_s?) || ""), "ordinal" => JSON::Any.new(ordinal)}
    when "source.lifecycle_changed"
      sid = payload["surface_id"]?.try(&.as_s?) || ""
      status = payload["status"]?.try(&.as_s?) || ""
      raise Chronicle::Packs::PackError.new("invalid explicit lifecycle status #{status.inspect}") unless Categories::EXPLICIT_LIFECYCLE_STATUSES.includes?(status)
      lifecycle[sid] = {"status" => JSON::Any.new(status), "reason" => payload["reason"]? || JSON::Any.new(""), "event_id" => JSON::Any.new(payload["event_id"]?.try(&.as_s?) || ""), "ordinal" => JSON::Any.new(ordinal)}
    when "source.cursor_advanced"
      sid = payload["source_surface_id"]?.try(&.as_s?) || payload["surface_id"]?.try(&.as_s?) || ""
      if surfaces.has_key?(sid)
        surfaces[sid]["cursor_state"] = JSON::Any.new({"oldest_ingested_ref" => payload["oldest_ingested_ref"]? || JSON::Any.new(nil), "newest_ingested_ref" => payload["newest_ingested_ref"]? || JSON::Any.new(nil), "cursor_version" => payload["cursor_version"]? || JSON::Any.new(1)})
      end
    end
  end

  # Apply evidence ingestion / invalidation events to the projection.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream evidence replay branches
  def self._apply_evidence_event(event_type : String, payload : Hash(String, JSON::Any), ordinal : Int32, evidence : Hash({String, String}, Hash(String, JSON::Any)), evidence_events_seen : Hash(String, Int32)) : Nil
    sid = payload["source_surface_id"]?.try(&.as_s?) || payload["surface_id"]?.try(&.as_s?) || ""
    identity = payload["evidence_identity"]?.try(&.as_s?) || ""
    key = {sid, identity}
    if event_type == "source.event_ingested"
      if !sid.empty? && !identity.empty?
        evidence_events_seen[sid] = (evidence_events_seen[sid]? || 0) + 1
        revision = payload.dup
        revision["event_id"] = JSON::Any.new(payload["event_id"]?.try(&.as_s?) || "")
        revision["ordinal"] = JSON::Any.new(ordinal)
        prior = evidence[key]?
        if prior.nil? || (revision["revision_number"]?.try(&.as_i) || 0) >= (prior["revision_number"]?.try(&.as_i) || 0)
          evidence[key] = revision
        end
      end
    elsif evidence.has_key?(key)
      invalidated = evidence[key].dup
      invalidated["invalidated"] = JSON::Any.new(true)
      invalidated["ordinal"] = JSON::Any.new(ordinal)
      evidence[key] = invalidated
    end
  end

  # Apply clock / usage-record / settled events to the projection.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream clock/usage/settled replay branches
  def self._apply_clock_usage_event(event_type : String, payload : Hash(String, JSON::Any), ordinal : Int32, clocks : Hash(String, Hash(String, Hash(String, JSON::Any))), usage_records : Hash(String, Hash(String, JSON::Any)), settled_events : Hash({String, String, Int32}, Hash(String, JSON::Any))) : Nil
    case event_type
    when "source.clock"
      sid = payload["surface_id"]?.try(&.as_s?) || ""
      clock_id = payload["clock_id"]?.try(&.as_s?) || payload["event_id"]?.try(&.as_s?) || ""
      per_surface = clocks[sid]? || {} of String => Hash(String, JSON::Any)
      clock_row = payload.dup
      clock_row["event_id"] = payload["event_id"]? || JSON::Any.new(nil)
      per_surface[clock_id] = clock_row unless per_surface.has_key?(clock_id)
      clocks[sid] = per_surface
    when "usage.recorded"
      usage_id = payload["usage_identity"]?.try(&.as_s?) || ""
      if !usage_id.empty?
        row = payload.dup
        row["event_id"] = payload["event_id"]? || JSON::Any.new(nil)
        usage_records[usage_id] = row unless usage_records.has_key?(usage_id)
      end
    when "source.settled"
      sid = payload["surface_id"]?.try(&.as_s?) || payload["source_surface_id"]?.try(&.as_s?) || ""
      gate_id = payload["gate_id"]?.try(&.as_s?) || Categories::DEFAULT_GATE["gate_id"].as_s
      gate_version = payload["gate_version"]?.try(&.as_i?) || Categories::DEFAULT_GATE["gate_version"].as_i
      key = {sid, gate_id, gate_version}
      row = payload.dup
      row["event_id"] = payload["event_id"]? || JSON::Any.new(nil)
      row["ordinal"] = JSON::Any.new(ordinal)
      settled_events[key] = row unless settled_events.has_key?(key)
    end
  end

  # Collect a non-fixed outcome event into the outcome list.
  def self._apply_outcome_event(event : Chronicle::Event, payload : Hash(String, JSON::Any), outcomes : Array(Hash(String, JSON::Any))) : Nil
    return unless event.type.starts_with?("outcome.")

    row = payload.dup
    row["event_type"] = JSON::Any.new(event.type)
    row["event_id"] = JSON::Any.new(event.id)
    outcomes << row
  end

  # Coverage statistics for one surface (typed projection sub-object).
  # Coverage statistics for one surface (typed projection sub-object).
  record CoverageStats,
    surface_id : String,
    category : String?,
    unique_evidence : Int32,
    visible_evidence_revisions : Int32,
    fixture_evidence : Int32,
    earliest : String?,
    latest : String?,
    coverage_days : Int32,
    volume_passed : Bool,
    coverage_passed : Bool do
    include JSON::Serializable
  end

  # Settlement state for one surface at its gate (typed projection sub-object).
  record SettlementProjection,
    surface_id : String,
    category : String?,
    status : String,
    gate_id : String,
    gate_version : Int32,
    min_unique_events : Int32,
    min_coverage_days : Int32,
    allow_either : Bool,
    passed : Bool,
    passed_by : String?,
    settled_event_id : String?,
    lifecycle_event_id : String?,
    lifecycle_reason : String do
    include JSON::Serializable
  end

  def self.project_usage_fn(graph : Chronicle::GraphProjection, event_horizon_event_id : String) : Hash(String, JSON::Any)
    events = _events_through(graph, event_horizon_event_id)
    surfaces = {} of String => Hash(String, JSON::Any)
    lifecycle = {} of String => Hash(String, JSON::Any)
    evidence = {} of {String, String} => Hash(String, JSON::Any)
    clocks = {} of String => Hash(String, Hash(String, JSON::Any))
    usage_records = {} of String => Hash(String, JSON::Any)
    settled_events = {} of {String, String, Int32} => Hash(String, JSON::Any)
    evidence_events_seen = {} of String => Int32
    gates = {} of {String, Int32} => Hash(String, JSON::Any)
    gates[{Categories::DEFAULT_GATE["gate_id"].as_s, Categories::DEFAULT_GATE["gate_version"].as_i}] = Categories::DEFAULT_GATE
    outcomes = [] of Hash(String, JSON::Any)

    events.each_with_index do |event, ordinal|
      payload = JSON.parse(event.payload).as_h
      case event.type
      when "object.created"
        _apply_created_event(payload, gates, usage_records)
      when "source.connected", "source.lifecycle_changed", "source.cursor_advanced"
        _apply_surface_event(event.type, payload, ordinal, surfaces, lifecycle)
      when "source.event_ingested", "source.event_invalidated", "source.evidence_invalidated"
        _apply_evidence_event(event.type, payload, ordinal, evidence, evidence_events_seen)
      when "source.clock", "usage.recorded", "source.settled"
        _apply_clock_usage_event(event.type, payload, ordinal, clocks, usage_records, settled_events)
      else
        _apply_outcome_event(event, payload, outcomes)
      end
    end

    _project_surface_rows(surfaces, lifecycle, evidence, clocks, gates, settled_events, evidence_events_seen, outcomes, usage_records)
  end

  # Project one surface into its row + coverage statistics.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream per-surface projection row
  def self._project_surface_row(sid : String, surface : Hash(String, JSON::Any), gates : Hash({String, Int32}, Hash(String, JSON::Any)), evidence : Hash({String, String}, Hash(String, JSON::Any)), clocks : Hash(String, Hash(String, Hash(String, JSON::Any))), lifecycle : Hash(String, Hash(String, JSON::Any)), settled_events : Hash({String, String, Int32}, Hash(String, JSON::Any)), evidence_events_seen : Hash(String, Int32)) : {CoverageStats, Hash(String, JSON::Any)}
    gate_key = {surface["gate_id"]?.try(&.as_s?) || "", surface["gate_version"]?.try(&.as_i?) || 1}
    gate = gates[gate_key]?
    raise Chronicle::Packs::PackError.new("surface #{sid.inspect} references unknown gate #{gate_key[0]}@#{gate_key[1]}") if gate.nil?
    current = evidence.select { |(surface_id, _identity), item| surface_id == sid && _qualifying_evidence(item, surface) }.values
    coverage = _surface_coverage(sid, surface, current, clocks)
    unique_events = current.size
    volume_passed = unique_events >= (gate["min_unique_events"]?.try(&.as_i) || 25)
    coverage_passed = coverage["coverage_days"].as_i >= (gate["min_coverage_days"]?.try(&.as_i) || 3)
    allow_either = gate["allow_either"]?.try(&.as_bool?) || true
    gate_passed = allow_either ? (volume_passed || coverage_passed) : (volume_passed && coverage_passed)
    passed_by = if volume_passed && coverage_passed
                  "both"
                elsif volume_passed
                  "volume"
                elsif coverage_passed
                  "coverage"
                else
                  nil
                end
    passed_thresholds = [] of JSON::Any
    passed_thresholds << JSON::Any.new("volume") if volume_passed
    passed_thresholds << JSON::Any.new("coverage") if coverage_passed
    contribution_key = {sid, gate_key[0], gate_key[1]}
    settled = settled_events[contribution_key]?
    explicit = lifecycle[sid]? || {"status" => JSON::Any.new("connected"), "reason" => JSON::Any.new("")}
    status = if explicit["status"]?.try(&.as_s?).in?({"stale", "revoked", "failed"})
               explicit["status"].as_s
             elsif gate_passed
               "settled"
             elsif settled
               "stale"
             elsif !current.empty?
               "settling"
             else
               "connected"
             end
    fixture_visible = evidence.count { |(surface_id, _identity), item| surface_id == sid && (item["is_fixture"]?.try(&.as_bool?) || false) }
    all_visible = evidence_events_seen[sid]? || 0
    stats = CoverageStats.new(
      sid, surface["category"]?.try(&.as_s?), unique_events, all_visible, fixture_visible,
      coverage["earliest"]?.try(&.as_s?), coverage["latest"]?.try(&.as_s?),
      coverage["coverage_days"]?.try(&.as_i) || 0, volume_passed, coverage_passed,
    )
    settlement = SettlementProjection.new(
      sid, surface["category"]?.try(&.as_s?), status, gate_key[0], gate_key[1],
      gate["min_unique_events"]?.try(&.as_i) || 25, gate["min_coverage_days"]?.try(&.as_i) || 3,
      gate["allow_either"]?.try(&.as_bool?) || true, gate_passed, passed_by,
      settled ? (settled["event_id"]?.try(&.as_s?)) : nil,
      explicit["event_id"]?.try(&.as_s?), explicit["reason"]?.try(&.as_s?) || "",
    )
    row = surface.dup
    row["status"] = JSON::Any.new(status)
    row["events_seen"] = JSON::Any.new(all_visible)
    row["unique_evidence_count"] = JSON::Any.new(unique_events)
    row["first_seen"] = coverage["earliest"]? || JSON::Any.new(nil)
    row["last_seen"] = coverage["latest"]? || JSON::Any.new(nil)
    row["settled_by"] = JSON::Any.new(status == "settled" ? passed_thresholds : [] of JSON::Any)
    row["settled_event_id"] = settled ? (settled["event_id"]? || JSON::Any.new(nil)) : JSON::Any.new(nil)
    row["coverage"] = JSON.parse(stats.to_json)
    row["settlement"] = JSON.parse(settlement.to_json)
    {stats, row}
  end

  # Coverage span for one surface's qualifying evidence (live sources add clock times).
  def self._surface_coverage(sid : String, surface : Hash(String, JSON::Any), current : Array(Hash(String, JSON::Any)), clocks : Hash(String, Hash(String, Hash(String, JSON::Any)))) : Hash(String, JSON::Any)
    provider_times = current.compact_map { |item| item["provider_time"]?.try(&.as_s?) if _parse_timestamp(item["provider_time"]?.try(&.as_s?)) }
    coverage_times = provider_times.dup
    if !current.empty? && (surface["acquisition_mode"]?.try(&.as_s?) == "live")
      coverage_times.concat(current.compact_map { |item| item["provider_time"]?.try(&.as_s?) || item["event_id"]?.try(&.as_s?) })
      coverage_times.concat((clocks[sid]? || {} of String => Hash(String, JSON::Any)).values.compact_map do |item|
        next nil if item["is_fixture"]?.try(&.as_bool?) || false

        item["observed_at"]?.try(&.as_s?) || item["event_id"]?.try(&.as_s?)
      end)
    end
    _coverage_from_times(coverage_times)
  end

  # Category-level coverage rollups.
  def self._project_category_coverage(surface_rows : Array(Hash(String, JSON::Any)), evidence : Hash({String, String}, Hash(String, JSON::Any)), surfaces : Hash(String, Hash(String, JSON::Any))) : Hash(String, Hash(String, JSON::Any))
    by_category = {} of String => Hash(String, JSON::Any)
    Categories::SOURCE_CATEGORIES.each do |category|
      category_surfaces = surface_rows.select { |row| row["category"]?.try(&.as_s?) == category }
      ids = Set({String, String}).new
      evidence.each do |(sid, identity), item|
        next unless category_surfaces.any? { |row| row["surface_id"]?.try(&.as_s?) == sid }

        ids << {sid, identity} if _qualifying_evidence(item, surfaces[sid])
      end
      times = [] of String?
      category_surfaces.each do |row|
        coverage = row["coverage"]?.try(&.as_h) || {} of String => JSON::Any
        times << coverage["earliest"]?.try(&.as_s?)
        times << coverage["latest"]?.try(&.as_s?)
      end
      coverage = _coverage_from_times(times.compact)
      by_category[category] = {
        "category"         => JSON::Any.new(category),
        "unique_evidence"  => JSON::Any.new(ids.size),
        "earliest"         => coverage["earliest"]? || JSON::Any.new(nil),
        "latest"           => coverage["latest"]? || JSON::Any.new(nil),
        "coverage_days"    => coverage["coverage_days"]? || JSON::Any.new(0),
        "surfaces"         => JSON::Any.new(category_surfaces.size),
        "settled_surfaces" => JSON::Any.new(category_surfaces.count { |row| row["status"]?.try(&.as_s?) == "settled" }),
      }
    end
    by_category
  end

  # Interaction tallies from usage records.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream usage tally
  def self._project_usage_stats(usage_records : Hash(String, Hash(String, JSON::Any)), surfaces : Hash(String, Hash(String, JSON::Any))) : {Hash(String, Hash(String, JSON::Any)), Hash(String, Hash(String, JSON::Any)), Array(Hash(String, JSON::Any))}
    usage_by_surface = {} of String => Hash(String, JSON::Any)
    usage_by_category = {} of String => Hash(String, JSON::Any)
    qualifying_usage = [] of Hash(String, JSON::Any)
    usage_records.each do |usage_id, record|
      sid = record["source_surface_id"]?.try(&.as_s?) || record["surface_id"]?.try(&.as_s?) || ""
      category_value = record["source_category"]?.try(&.as_s?) || record["category"]?.try(&.as_s?)
      if category_value
        category_value = validate_source_category(category_value)
      end
      next if record["is_fixture"]?.try(&.as_bool?) || false || !surfaces.has_key?(sid)
      next if surfaces[sid]["is_fixture"]?.try(&.as_bool?) || false

      category_value = category_value || surfaces[sid]["category"]?.try(&.as_s?) || ""
      kind = record["interaction_type"]?.try(&.as_s?) || record["kind"]?.try(&.as_s?) || "interaction"
      amount = record["count"]?.try(&.as_i) || 1
      surface_counter = usage_by_surface[sid]? || _empty_counter
      _increment_counter(surface_counter, kind, amount)
      usage_by_surface[sid] = surface_counter
      category_counter = usage_by_category[category_value]? || _empty_counter
      _increment_counter(category_counter, kind, amount)
      usage_by_category[category_value] = category_counter
      qualifying_usage << record.merge({"usage_identity" => JSON::Any.new(usage_id)})
    end
    {usage_by_surface, usage_by_category, qualifying_usage}
  end

  # Outcome tallies from terminal/maintenance outcome events.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream outcome tally with dedup keys
  def self._project_outcome_stats(outcomes : Array(Hash(String, JSON::Any)), surfaces : Hash(String, Hash(String, JSON::Any))) : {Hash(String, Hash(String, JSON::Any)), Hash(String, Hash(String, JSON::Any)), Array(Hash(String, JSON::Any))}
    outcome_by_surface = {} of String => Hash(String, JSON::Any)
    outcome_by_category = {} of String => Hash(String, JSON::Any)
    seen_terminal = Set(String).new
    seen_outcome_keys = Set(String).new
    qualifying_outcomes = [] of Hash(String, JSON::Any)
    outcomes.each do |outcome|
      next if outcome["is_fixture"]?.try(&.as_bool?) || false

      event_type = outcome["event_type"].as_s
      if Categories::TERMINAL_OUTCOMES.includes?(event_type)
        evaluation_id = outcome["evaluation_id"]?.try(&.as_s?) || ""
        next if !evaluation_id.empty? && seen_terminal.includes?(evaluation_id)
        seen_terminal << evaluation_id unless evaluation_id.empty?
        key = evaluation_id.empty? ? "terminal:#{outcome["event_id"].as_s}" : "terminal:#{evaluation_id}"
      else
        key = outcome["contribution_key"]?.try(&.as_s?) || outcome["event_id"].as_s
      end
      next if seen_outcome_keys.includes?(key)
      seen_outcome_keys << key
      sid = outcome["source_surface_id"]?.try(&.as_s?) || outcome["surface_id"]?.try(&.as_s?) || ""
      next if surfaces.has_key?(sid) && (surfaces[sid]["is_fixture"]?.try(&.as_bool?) || false)

      category = outcome["source_category"]?.try(&.as_s?) || outcome["category"]?.try(&.as_s?)
      category = validate_source_category(category) if category
      if category.nil? && (surface_row = surfaces[sid]?)
        category = surface_row["category"]?.try(&.as_s?)
      end
      kind = event_type.sub("outcome.", "")
      if surfaces.has_key?(sid) && !(surfaces[sid]["is_fixture"]?.try(&.as_bool?) || false)
        surface_counter = outcome_by_surface[sid]? || _empty_counter
        _increment_counter(surface_counter, kind)
        outcome_by_surface[sid] = surface_counter
      end
      if category && Categories::SOURCE_CATEGORY_SET.includes?(category)
        category_counter = outcome_by_category[category]? || _empty_counter
        _increment_counter(category_counter, kind)
        outcome_by_category[category] = category_counter
      end
      qualifying_outcomes << outcome
    end
    {outcome_by_surface, outcome_by_category, qualifying_outcomes}
  end

  def self._project_surface_rows(surfaces : Hash(String, Hash(String, JSON::Any)), lifecycle : Hash(String, Hash(String, JSON::Any)), evidence : Hash({String, String}, Hash(String, JSON::Any)), clocks : Hash(String, Hash(String, Hash(String, JSON::Any))), gates : Hash({String, Int32}, Hash(String, JSON::Any)), settled_events : Hash({String, String, Int32}, Hash(String, JSON::Any)), evidence_events_seen : Hash(String, Int32), outcomes : Array(Hash(String, JSON::Any)), usage_records : Hash(String, Hash(String, JSON::Any))) : Hash(String, JSON::Any)
    by_surface = {} of String => Hash(String, JSON::Any)
    surface_rows = [] of Hash(String, JSON::Any)
    by_surface = {} of String => Hash(String, JSON::Any)
    surface_rows = [] of Hash(String, JSON::Any)
    surfaces.keys.sort!.each do |sid|
      stats, row = _project_surface_row(sid, surfaces[sid], gates, evidence, clocks, lifecycle, settled_events, evidence_events_seen)
      by_surface[sid] = JSON.parse(stats.to_json).as_h
      surface_rows << row
    end

    by_category = _project_category_coverage(surface_rows, evidence, surfaces)
    usage_by_surface, usage_by_category, qualifying_usage = _project_usage_stats(usage_records, surfaces)
    outcome_by_surface, outcome_by_category, qualifying_outcomes = _project_outcome_stats(outcomes, surfaces)

    {
      "event_horizon_event_id" => JSON::Any.new(""),
      "surfaces"               => JSON::Any.new(surface_rows.map { |row| JSON::Any.new(row) }),
      "coverage"               => JSON::Any.new({"by_surface" => JSON::Any.new(by_surface.transform_values { |v| JSON::Any.new(v) }), "by_category" => JSON::Any.new(by_category.transform_values { |v| JSON::Any.new(v) })}),
      "usage"                  => JSON::Any.new({"total" => JSON::Any.new(qualifying_usage.sum { |record| record["count"]?.try(&.as_i) || 1 }), "by_surface" => JSON::Any.new(usage_by_surface.transform_values { |v| JSON::Any.new(v) }), "by_category" => JSON::Any.new(usage_by_category.transform_values { |v| JSON::Any.new(v) })}),
      "outcomes"               => JSON::Any.new({"total" => JSON::Any.new(qualifying_outcomes.size), "by_surface" => JSON::Any.new(outcome_by_surface.transform_values { |v| JSON::Any.new(v) }), "by_category" => JSON::Any.new(outcome_by_category.transform_values { |v| JSON::Any.new(v) })}),
    }
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream surface-from-event defaults
  def self._surface_from_connected(payload : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    surface_id = payload["surface_id"]?.try(&.as_s?) || payload["id"]?.try(&.as_s?) || ""
    raise Chronicle::Packs::PackError.new("connection surface event is missing surface_id") if surface_id.empty?
    category = validate_source_category(payload["category"]?.try(&.as_s?) || "")
    path = payload["path"]?.try(&.as_s?) || ""
    raise Chronicle::Packs::PackError.new("surface #{surface_id.inspect} has unknown connection path #{path.inspect}") unless Categories::CONNECTION_PATHS.includes?(path)
    {
      "id"                    => JSON::Any.new(surface_id),
      "surface_id"            => JSON::Any.new(surface_id),
      "surface_object_id"     => payload["surface_object_id"]? || JSON::Any.new(nil),
      "category"              => JSON::Any.new(category),
      "provider"              => payload["provider"]? || JSON::Any.new({} of String => JSON::Any),
      "path"                  => JSON::Any.new(path),
      "adapter"               => payload["adapter"]? || JSON::Any.new(nil),
      "acquisition_mode"      => payload["acquisition_mode"]? || JSON::Any.new("snapshot"),
      "privacy_scope"         => payload["privacy_scope"]? || JSON::Any.new("source"),
      "cursor_state"          => payload["cursor_state"]? || JSON::Any.new(_cursor_default),
      "events_seen"           => payload["events_seen"]? || JSON::Any.new(0),
      "unique_evidence_count" => payload["unique_evidence_count"]? || JSON::Any.new(0),
      "first_seen"            => payload["first_seen"]? || JSON::Any.new(nil),
      "last_seen"             => payload["last_seen"]? || JSON::Any.new(nil),
      "is_fixture"            => payload["is_fixture"]? || JSON::Any.new(false),
      "metadata"              => payload["metadata"]? || JSON::Any.new({} of String => JSON::Any),
      "gate_id"               => payload["gate_id"]? || Categories::DEFAULT_GATE["gate_id"],
      "gate_version"          => payload["gate_version"]? || Categories::DEFAULT_GATE["gate_version"],
      "settled_by"            => payload["settled_by"]? || JSON::Any.new([] of JSON::Any),
      "settled_event_id"      => payload["settled_event_id"]? || JSON::Any.new(nil),
    }
  end

  def self.list_surfaces_fn(graph : Chronicle::GraphProjection, event_horizon_event_id : String) : Array(JSON::Any)
    project_usage_fn(graph, event_horizon_event_id)["surfaces"].as_a
  end

  def self.get_settlement_fn(graph : Chronicle::GraphProjection, event_horizon_event_id : String, surface_id : String? = nil) : JSON::Any
    rows = project_usage_fn(graph, event_horizon_event_id)["surfaces"].as_a
    settlements = rows.map { |row| row["settlement"]? || JSON::Any.new(nil) }
    if surface_id.nil?
      JSON::Any.new(settlements)
    else
      found = settlements.find { |row| row["surface_id"]?.try(&.as_s?) == surface_id }
      found || JSON::Any.new(nil)
    end
  end

  def self.get_coverage_fn(graph : Chronicle::GraphProjection, event_horizon_event_id : String) : JSON::Any
    project_usage_fn(graph, event_horizon_event_id)["coverage"]? || JSON::Any.new(nil)
  end

  def self.get_usage_stats_fn(graph : Chronicle::GraphProjection, event_horizon_event_id : String) : JSON::Any
    project_usage_fn(graph, event_horizon_event_id)["usage"]? || JSON::Any.new(nil)
  end

  def self.get_outcome_stats_fn(graph : Chronicle::GraphProjection, event_horizon_event_id : String) : JSON::Any
    project_usage_fn(graph, event_horizon_event_id)["outcomes"]? || JSON::Any.new(nil)
  end

  # ---- tools ---------------------------------------------------------------

  # Typed parameter structs for the graph tools. Each is JSON::Serializable
  # so args parse into a typed struct (instead of JSON::Any hash chains) and
  # the same struct can serve as a JSON Schema source for agent adapters.

  # ISO-8601 Time converter for tool parameter structs.
  module Iso8601Time
    def self.from_json(pull : JSON::PullParser) : Time
      Time.parse_iso8601(pull.read_string)
    end

    def self.to_json(value : Time, json : JSON::Builder) : Nil
      json.string(value.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ"))
    end
  end

  record HorizonParams,
    event_horizon_event_id : String = "" do
    include JSON::Serializable
  end

  record SettlementQueryParams,
    event_horizon_event_id : String = "",
    surface_id : String? = nil do
    include JSON::Serializable
  end

  record ConnectSurfaceParams,
    surface_id : String = "",
    category : String = "",
    provider : Hash(String, JSON::Any) = {} of String => JSON::Any,
    path : String = "native",
    adapter : String? = nil,
    acquisition_mode : String = "snapshot",
    privacy_scope : String = "source",
    fixture : Bool = false do
    include JSON::Serializable
    @[JSON::Field(key: "is_fixture")]
    getter fixture : Bool = false
  end

  record SetSurfaceStatusParams,
    surface_id : String = "",
    status : String = "",
    reason : String = "" do
    include JSON::Serializable
  end

  record RecordSourceClockParams,
    observed_at : Time,
    surface_id : String = "",
    clock_id : String? = nil,
    fixture : Bool = false do
    include JSON::Serializable
    @[JSON::Field(converter: Iso8601Time)]
    getter observed_at : Time
    @[JSON::Field(key: "is_fixture")]
    getter fixture : Bool = false
  end

  record RecordUsageParams,
    usage_identity : String = "",
    surface_id : String = "",
    interaction_type : String = "interaction",
    evidence_identity : String? = nil,
    provider_time : Time? = nil,
    count : Int32 = 1,
    fixture : Bool = false do
    include JSON::Serializable
    @[JSON::Field(converter: Iso8601Time)]
    getter provider_time : Time?
    @[JSON::Field(key: "is_fixture")]
    getter fixture : Bool = false
  end

  @[Chronicle::Packs::Annotations::Tool(name: "connect_source_surface", description: "Create or reconnect one canonical source surface and record the connection fact.", deterministic: true)]
  def connect_source_surface_tool(args : String) : String
    params = ConnectSurfaceParams.from_json(args)
    result = connect_surface_fn(
      bound_graph_or_raise,
      params.surface_id, params.category,
      provider: params.provider,
      path: params.path,
      adapter: params.adapter,
      acquisition_mode: params.acquisition_mode,
      privacy_scope: params.privacy_scope,
      is_fixture: params.fixture,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "set_source_surface_status", description: "Record an explicit connected, stale, revoked, or failed source lifecycle fact.", deterministic: true)]
  # ameba:disable Naming/AccessorMethodName -- chronicle tool-name convention (`set_` prefix)
  def set_source_surface_status_tool(args : String) : String
    params = SetSurfaceStatusParams.from_json(args)
    result = set_surface_status_fn(bound_graph_or_raise, params.surface_id, params.status, reason: params.reason)
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_source_clock", description: "Record an explicit clock input for historical live-source coverage.", deterministic: true)]
  def record_source_clock_tool(args : String) : String
    params = RecordSourceClockParams.from_json(args)
    result = record_source_clock_fn(
      bound_graph_or_raise, params.surface_id, _fmt_iso8601(params.observed_at),
      clock_id: params.clock_id, is_fixture: params.fixture,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_usage", description: "Record one idempotent interaction fact for a connected source surface.", deterministic: true)]
  def record_usage_tool(args : String) : String
    params = RecordUsageParams.from_json(args)
    result = record_usage_fn(
      bound_graph_or_raise,
      params.usage_identity, params.surface_id, params.interaction_type,
      evidence_identity: params.evidence_identity,
      provider_time: params.provider_time.try { |time| _fmt_iso8601(time) },
      count: params.count,
      is_fixture: params.fixture,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "query_usage", description: "Read the complete neutral projection at an explicit event horizon.", deterministic: true)]
  def query_usage_tool(args : String) : String
    params = HorizonParams.from_json(args)
    project_usage_fn(bound_graph_or_raise, params.event_horizon_event_id).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "list_source_surfaces", description: "List source surfaces and their deterministic state at an explicit event horizon.", deterministic: true)]
  def list_source_surfaces_tool(args : String) : String
    params = HorizonParams.from_json(args)
    JSON::Any.new(list_surfaces_fn(bound_graph_or_raise, params.event_horizon_event_id)).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_settlement_state", description: "Read named and versioned source settlement facts at an explicit event horizon.", deterministic: true)]
  def get_settlement_state_tool(args : String) : String
    params = SettlementQueryParams.from_json(args)
    get_settlement_fn(bound_graph_or_raise, params.event_horizon_event_id, params.surface_id).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_coverage_statistics", description: "Read unique evidence and historical-span statistics at an explicit event horizon.", deterministic: true)]
  def get_coverage_statistics_tool(args : String) : String
    params = HorizonParams.from_json(args)
    get_coverage_fn(bound_graph_or_raise, params.event_horizon_event_id).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_usage_statistics", description: "Read interaction statistics at an explicit event horizon.", deterministic: true)]
  def get_usage_statistics_tool(args : String) : String
    params = HorizonParams.from_json(args)
    get_usage_stats_fn(bound_graph_or_raise, params.event_horizon_event_id).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_outcome_statistics", description: "Read terminal and maintenance outcome tallies at an explicit event horizon.", deterministic: true)]
  def get_outcome_statistics_tool(args : String) : String
    params = HorizonParams.from_json(args)
    get_outcome_stats_fn(bound_graph_or_raise, params.event_horizon_event_id).to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "usage tools require a bound graph (set Usage.bound_graph)"
    )
  end
end

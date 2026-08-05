require "json"
require "digest"

module Chronicle::Packs::ConnectorControl
  # Idempotent connector adapters and neutral control-plane queries. Ported
  # from upstream packs/connector_control/tools.py.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module ControlPlane
    CONTRACT_VERSION = "connector_control@0.1.0"
    TERMINAL_STATES  = Set(String).new(["succeeded", "partial", "failed"])
    SUCCESS_STATES   = Set(String).new(["succeeded", "partial"])
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self.stable_connector_id(prefix : String, *parts) : String
    material = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  # The single object claiming a field value, or nil.
  def self._by_field(graph : Chronicle::GraphProjection, object_type : String, field : String, value : String) : Chronicle::GraphObject?
    matches = graph.objects(type: object_type).select { |obj| (JSON.parse(obj.data)[field]?).try(&.as_s?) == value }
    raise Chronicle::Packs::PackError.new("multiple #{object_type} objects claim #{field}=#{value.inspect}") if matches.size > 1
    matches.first?
  end

  # Append a value to a list unless present.
  def self._append(values : Array(String), value : String?) : Array(String)
    out = values.dup
    if value && !value.empty? && !out.includes?(value)
      out << value
    end
    out
  end

  # Upsert an adapter output by its identity field; immutable fields cannot
  # change, changed fields are merged onto the existing object.
  def self._upsert(graph : Chronicle::GraphProjection, object_type : String, identity_field : String, payload : Hash(String, JSON::Any), immutable : Array(String)) : {Chronicle::GraphObject, Bool}
    existing = _by_field(graph, object_type, identity_field, (payload[identity_field]?.try(&.as_s?) || ""))
    if existing.nil?
      obj = graph.add_object(object_type, JSON::Any.new(payload).to_json)
      return {obj, true}
    end
    existing_data = JSON.parse(existing.data).as_h
    immutable.each do |field|
      if existing_data[field]? != payload[field]?
        raise Chronicle::Packs::PackError.new("#{object_type} #{payload[identity_field].inspect} cannot change #{field}")
      end
    end
    updates = {} of String => JSON::Any
    payload.each do |key, value|
      updates[key] = value if existing_data[key]? != value
    end
    if !updates.empty?
      _patch(graph, existing.id, updates)
      obj = graph.get_object(existing.id)
      return {obj || existing, false}
    end
    {existing, false}
  end

  def self.record_connector_binding_fn(graph : Chronicle::GraphProjection, source_surface_id : String, service : String, account_ref : String, family : String, active_route : String, domain_run_type : String, routes : Array(String)? = nil, native_shape_version : Int32 = 1, maintenance_mode : String = "none", manual_refresh_available : Bool = false, status : String = "active", metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    identity = stable_connector_id("connector_binding", source_surface_id, service, account_ref, family)
    existing = _by_field(graph, "connector_surface_binding", "binding_identity", identity)
    prior_routes = existing ? (JSON.parse(existing.data)["routes"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String) : [] of String
    all_routes = _dedup(prior_routes + (routes || [] of String) + [active_route])
    family_enum = ConnectorFamily.parse?(family)
    if family_enum.nil?
      raise Chronicle::Packs::PackError.new("unknown family #{family.inspect}")
    end
    payload = ConnectorSurfaceBinding.new(
      identity, source_surface_id, service, account_ref, family_enum, active_route, domain_run_type,
      routes: all_routes, native_shape_version: native_shape_version,
      maintenance_mode: MaintenanceMode.parse?(maintenance_mode) || MaintenanceMode::None, manual_refresh_available: manual_refresh_available,
      status: BindingStatus.parse?(status) || BindingStatus::Active, metadata: metadata,
    )
    obj, created = _upsert(graph, "connector_surface_binding", "binding_identity", JSON.parse(payload.to_json).as_h, ["source_surface_id", "service", "account_ref", "family"])
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "binding" => JSON::Any.new(obj.id)}
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream run-observation adapter
  def self.record_connector_run_observation_fn(graph : Chronicle::GraphProjection, domain_run_id : String, source_surface_id : String, service : String, account_ref : String, family : String, route : String, state : String, phase : String, mode : String, source_event_id : String? = nil, attempt : Bool = false, health : String? = nil, bounds : Hash(String, JSON::Any) = {} of String => JSON::Any, counts : Hash(String, Int64) = {} of String => Int64, cursor : Hash(String, JSON::Any) = {} of String => JSON::Any, maintenance_mode : String = "none", manual_refresh_available : Bool = false, next_sync_available : Bool = false, error_code : String? = nil, error : String? = nil, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    identity = stable_connector_id("connector_run", domain_run_id)
    existing = _by_field(graph, "connector_run_observation", "observation_identity", identity)
    prior = existing ? JSON.parse(existing.data).as_h : {} of String => JSON::Any
    derived_health = health || {
      "queued"    => "connected",
      "running"   => "working",
      "succeeded" => "current",
      "partial"   => "partial",
      "failed"    => "failed",
    }[state]
    updates = _append(prior["update_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String, source_event_id)
    attempts = _append(prior["attempt_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String, attempt ? source_event_id : nil)
    terminals = _append(prior["terminal_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String, ControlPlane::TERMINAL_STATES.includes?(state) ? source_event_id : nil)
    successes = _append(prior["success_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String, ControlPlane::SUCCESS_STATES.includes?(state) ? source_event_id : nil)
    family_enum = ConnectorFamily.parse?(family)
    if family_enum.nil?
      raise Chronicle::Packs::PackError.new("unknown family #{family.inspect}")
    end
    state_enum = ConnectorRunState.parse?(state)
    if state_enum.nil?
      raise Chronicle::Packs::PackError.new("unknown state #{state.inspect}")
    end
    payload = ConnectorRunObservation.new(
      identity, domain_run_id, source_surface_id, service, account_ref, family_enum, route,
      state_enum, ConnectorRunHealth.parse?(derived_health) || ConnectorRunHealth::Connected, phase, mode,
      bounds: bounds, counts: counts, cursor: CursorSummary.from_json(JSON::Any.new(cursor).to_json),
      attempt_event_ids: attempts, update_event_ids: updates,
      terminal_event_ids: terminals, success_event_ids: successes,
      maintenance_mode: MaintenanceMode.parse?(maintenance_mode) || MaintenanceMode::None, manual_refresh_available: manual_refresh_available,
      next_sync_available: next_sync_available, error_code: error_code,
      error: error ? error[0, 500] : nil, metadata: metadata,
    )
    obj, created = _upsert(graph, "connector_run_observation", "observation_identity", JSON.parse(payload.to_json).as_h, ["domain_run_id", "source_surface_id", "service", "account_ref", "family"])
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "observation" => JSON::Any.new(obj.id)}
  end

  def self.record_connector_learning_delta_fn(graph : Chronicle::GraphProjection, domain_run_id : String, source_surface_id : String, service : String, family : String, status : String = "collecting", evidence : Hash(String, Int64) = {} of String => Int64, annotation_coverage : Hash(String, Int64) = {} of String => Int64, resolutions : Hash(String, Int64) = {} of String => Int64, candidates : Hash(String, Hash(String, Int64)) = {} of String => Hash(String, Int64), failures : Int32 = 0, exceptions : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any), cost : Hash(String, JSON::Any) = {} of String => JSON::Any, refs : Array(String) = [] of String, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any, settings : ConnectorControlSettings = ConnectorControlSettings.new) : Hash(String, JSON::Any)
    identity = stable_connector_id("connector_delta", domain_run_id)
    family_enum = ConnectorFamily.parse?(family)
    if family_enum.nil?
      raise Chronicle::Packs::PackError.new("unknown family #{family.inspect}")
    end
    payload = ConnectorLearningDelta.new(
      identity, domain_run_id, source_surface_id, service, family_enum,
      status: DeltaStatus.parse?(status) || DeltaStatus::Collecting, evidence: evidence, annotation_coverage: annotation_coverage,
      resolutions: resolutions, candidates: candidates, failures: failures,
      exceptions: exceptions[0, settings.max_exceptions_per_delta],
      cost: cost, refs: _dedup(refs)[0, settings.max_refs_per_delta], metadata: metadata,
    )
    obj, created = _upsert(graph, "connector_learning_delta", "delta_identity", JSON.parse(payload.to_json).as_h, ["domain_run_id", "source_surface_id", "service", "family"])
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "delta" => JSON::Any.new(obj.id)}
  end

  def self.record_connector_native_view_fn(graph : Chronicle::GraphProjection, source_surface_id : String, service : String, family : String, state : String, data : Hash(String, JSON::Any) = {} of String => JSON::Any, shape_version : Int32 = 1, refs : Array(String) = [] of String, service_extensions : Hash(String, JSON::Any) = {} of String => JSON::Any, error : String? = nil) : Hash(String, JSON::Any)
    identity = stable_connector_id("connector_native_view", source_surface_id, family)
    canonical_data = validate_native_data(family, data)
    family_enum = ConnectorFamily.parse?(family)
    if family_enum.nil?
      raise Chronicle::Packs::PackError.new("unknown family #{family.inspect}")
    end
    payload = ConnectorNativeView.new(
      identity, source_surface_id, service, family_enum, NativeViewState.parse?(state) || NativeViewState::Empty, data: canonical_data,
      shape_version: shape_version, refs: _dedup(refs),
      service_extensions: service_extensions, error: error ? error[0, 500] : nil,
    )
    obj, created = _upsert(graph, "connector_native_view", "view_identity", JSON.parse(payload.to_json).as_h, ["source_surface_id", "service", "family", "shape_version"])
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "view" => JSON::Any.new(obj.id)}
  end

  # Dedup preserving first occurrence (upstream dict.fromkeys).
  def self._dedup(values : Array(String)) : Array(String)
    out = [] of String
    values.each { |value| out << value unless out.includes?(value) }
    out
  end

  def self._event_index(graph : Chronicle::GraphProjection) : Hash(String, JSON::Any)
    index = {} of String => JSON::Any
    graph.events.each do |event|
      index[event.id] = JSON::Any.new({"event_id" => JSON::Any.new(event.id), "timestamp" => JSON::Any.new(event.timestamp.to_unix_ms)})
    end
    index
  end

  # Sorted binding rows with their graph object id.
  def self._project_bindings(graph : Chronicle::GraphProjection) : Array(Hash(String, JSON::Any))
    rows = graph.objects(type: "connector_surface_binding").map do |obj|
      JSON.parse(obj.data).as_h.merge({"binding_object_id" => JSON::Any.new(obj.id)})
    end
    rows.sort_by! { |row| {row["service"]?.try(&.as_s?) || "", row["account_ref"]?.try(&.as_s?) || "", row["source_surface_id"]?.try(&.as_s?) || ""} }
    rows
  end

  # The newest indexed event for a trace, or null.
  def self._last_trace_event(event_index : Hash(String, JSON::Any), event_ids : Array(String)) : JSON::Any
    return JSON::Any.new(nil) if event_ids.empty?

    event_index[event_ids.last]? || JSON::Any.new(nil)
  end

  # Run rows with event-trace lookups, sorted by last update.
  def self._project_runs(graph : Chronicle::GraphProjection, event_index : Hash(String, JSON::Any)) : Array(Hash(String, JSON::Any))
    rows = [] of Hash(String, JSON::Any)
    graph.objects(type: "connector_run_observation").each do |obj|
      data = JSON.parse(obj.data).as_h
      attempts = data["attempt_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
      successes = data["success_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
      updates = data["update_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
      row = data.merge({
        "observation_object_id" => JSON::Any.new(obj.id),
        "last_attempt"          => _last_trace_event(event_index, attempts),
        "last_success"          => _last_trace_event(event_index, successes),
        "last_update"           => _last_trace_event(event_index, updates),
        "current_work_ref"      => data["domain_run_id"]? || JSON::Any.new(nil),
      })
      rows << row
    end
    rows.sort_by! { |row| {(row["last_update"]?.try(&.as_h?) || {} of String => JSON::Any)["event_id"]?.try(&.as_s?) || "", row["observation_identity"]?.try(&.as_s?) || ""} }
    rows
  end

  # Sorted native-view rows with their graph object id.
  def self._project_native_views(graph : Chronicle::GraphProjection) : Array(Hash(String, JSON::Any))
    rows = graph.objects(type: "connector_native_view").map do |obj|
      JSON.parse(obj.data).as_h.merge({"view_object_id" => JSON::Any.new(obj.id)})
    end
    rows.sort_by! { |row| {row["source_surface_id"]?.try(&.as_s?) || "", row["family"]?.try(&.as_s?) || ""} }
    rows
  end

  def self.project_connector_control_plane_fn(graph : Chronicle::GraphProjection) : Hash(String, JSON::Any)
    event_index = _event_index(graph)
    bindings = _project_bindings(graph)
    runs = _project_runs(graph, event_index)
    views = _project_native_views(graph)
    {"contract_version" => JSON::Any.new(ControlPlane::CONTRACT_VERSION), "bindings" => JSON::Any.new(bindings.map { |row| JSON::Any.new(row) }), "runs" => JSON::Any.new(runs.map { |row| JSON::Any.new(row) }), "native_views" => JSON::Any.new(views.map { |row| JSON::Any.new(row) })}
  end

  def self.project_connector_learning_deltas_fn(graph : Chronicle::GraphProjection) : Hash(String, JSON::Any)
    rows = graph.objects(type: "connector_learning_delta").map do |obj|
      JSON.parse(obj.data).as_h.merge({"delta_object_id" => JSON::Any.new(obj.id)})
    end
    rows.sort_by! { |row| {row["service"]?.try(&.as_s?) || "", row["source_surface_id"]?.try(&.as_s?) || "", row["domain_run_id"]?.try(&.as_s?) || ""} }
    {"contract_version" => JSON::Any.new(ControlPlane::CONTRACT_VERSION), "deltas" => JSON::Any.new(rows.map { |row| JSON::Any.new(row) })}
  end

  # Input-extraction helpers for tool wrappers (keep cyclomatic complexity low).
  private def self._s(input : Hash(String, JSON::Any), key : String, default : String) : String
    input[key]?.try(&.as_s?) || default
  end

  private def self._s?(input : Hash(String, JSON::Any), key : String) : String?
    input[key]?.try(&.as_s?)
  end

  private def self._b(input : Hash(String, JSON::Any), key : String, default : Bool) : Bool
    input[key]?.try(&.as_bool?) || default
  end

  private def self._i(input : Hash(String, JSON::Any), key : String, default : Int32) : Int32
    input[key]?.try(&.as_i?) || default
  end

  private def self._h(input : Hash(String, JSON::Any), key : String) : Hash(String, JSON::Any)
    input[key]?.try(&.as_h) || {} of String => JSON::Any
  end

  private def self._a(input : Hash(String, JSON::Any), key : String) : Array(String)?
    input[key]?.try(&.as_a?.try(&.map(&.as_s)))
  end

  private def self._i64_map(input : Hash(String, JSON::Any), key : String) : Hash(String, Int64)
    _h(input, key).transform_values(&.as_i64)
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_connector_binding", description: "Bind one service surface to a connector family.", deterministic: true)]
  def record_connector_binding_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_connector_binding_fn(
      bound_graph_or_raise,
      _s(input, "source_surface_id", ""), _s(input, "service", ""),
      _s(input, "account_ref", ""), _s(input, "family", "conversation"),
      _s(input, "active_route", "native"), _s(input, "domain_run_type", "connector_run"),
      routes: _a(input, "routes"),
      native_shape_version: _i(input, "native_shape_version", 1),
      maintenance_mode: _s(input, "maintenance_mode", "none"),
      manual_refresh_available: _b(input, "manual_refresh_available", false),
      status: _s(input, "status", "active"),
      metadata: _h(input, "metadata"),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_connector_run_observation", description: "Adapt an authoritative domain run into neutral connector state.", deterministic: true)]
  def record_connector_run_observation_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_connector_run_observation_fn(
      bound_graph_or_raise,
      _s(input, "domain_run_id", ""), _s(input, "source_surface_id", ""),
      _s(input, "service", ""), _s(input, "account_ref", ""),
      _s(input, "family", "conversation"), _s(input, "route", "native"),
      _s(input, "state", "queued"), _s(input, "phase", "queued"),
      _s(input, "mode", "manual"),
      source_event_id: _s?(input, "source_event_id"),
      attempt: _b(input, "attempt", false),
      health: _s?(input, "health"),
      bounds: _h(input, "bounds"),
      counts: _i64_map(input, "counts"),
      cursor: _h(input, "cursor"),
      maintenance_mode: _s(input, "maintenance_mode", "none"),
      manual_refresh_available: _b(input, "manual_refresh_available", false),
      next_sync_available: _b(input, "next_sync_available", false),
      error_code: _s?(input, "error_code"), error: _s?(input, "error"),
      metadata: _h(input, "metadata"),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_connector_learning_delta", description: "Record run-scoped learning counts and provenance.", deterministic: true)]
  def record_connector_learning_delta_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_connector_learning_delta_fn(
      bound_graph_or_raise,
      _s(input, "domain_run_id", ""), _s(input, "source_surface_id", ""),
      _s(input, "service", ""), _s(input, "family", "conversation"),
      status: _s(input, "status", "collecting"),
      evidence: _i64_map(input, "evidence"),
      annotation_coverage: _i64_map(input, "annotation_coverage"),
      resolutions: _i64_map(input, "resolutions"),
      failures: _i(input, "failures", 0),
      exceptions: input["exceptions"]?.try(&.as_a?.try(&.map(&.as_h))) || [] of Hash(String, JSON::Any),
      cost: _h(input, "cost"),
      refs: _a(input, "refs") || [] of String,
      metadata: _h(input, "metadata"),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_connector_native_view", description: "Record a validated family-native connector view.", deterministic: true)]
  def record_connector_native_view_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_connector_native_view_fn(
      bound_graph_or_raise,
      _s(input, "source_surface_id", ""), _s(input, "service", ""),
      _s(input, "family", "conversation"), _s(input, "state", "empty"),
      data: _h(input, "data"),
      shape_version: _i(input, "shape_version", 1),
      refs: _a(input, "refs") || [] of String,
      service_extensions: _h(input, "service_extensions"),
      error: _s?(input, "error"),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "project_connector_control_plane", description: "Project neutral connector status and native views.", deterministic: true)]
  def project_connector_control_plane_tool(args : String) : String
    project_connector_control_plane_fn(bound_graph_or_raise).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "project_connector_learning_deltas", description: "Project run-scoped connector learning deltas.", deterministic: true)]
  def project_connector_learning_deltas_tool(args : String) : String
    project_connector_learning_deltas_fn(bound_graph_or_raise).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_connector_refresh", description: "Request bounded maintenance through a connector's registered service adapter.", deterministic: true)]
  def request_connector_refresh_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = request_connector_refresh_fn(
      bound_graph_or_raise,
      input["source_surface_id"]?.try(&.as_s?) || "",
      requested_by: input["requested_by"]?.try(&.as_s?) || "owner",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "connector_control tools require a bound graph (set ConnectorControl.bound_graph)"
    )
  end
end

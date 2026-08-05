require "json"

module Chronicle::Packs::ConnectorControl
  # Versioned connector budgets and a non-persisted conformance measurer.
  # Ported from upstream packs/connector_control/operational.py.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module Policy
    OPERATIONAL_POLICY_ID = "connector-operational@0.1.0"
  end

  def self.operational_policy_payload : Hash(String, JSON::Any)
    policy = ConnectorOperationalPolicy.new(
      Policy::OPERATIONAL_POLICY_ID,
      "ADR 0034 provisional local release bounds for the recorded 250-item deterministic connector fixture",
    )
    JSON.parse(policy.to_json).as_h
  end

  # A non-persisted run conformance measurement.
  struct ConnectorOperationalMeasurement
    getter policy_identity : String = Policy::OPERATIONAL_POLICY_ID
    getter domain_run_id : String
    getter evidence_items : Int32
    getter durable_events : Int32
    getter events_per_evidence : Float64
    getter annotations : Int32
    getter max_annotations_for_one_evidence : Int32
    getter behavior_firings : Int32
    getter behavior_firings_per_evidence : Float64
    getter provider_calls : Int32
    getter artifact_bytes : Int32
    getter max_queue_depth : Int32?
    getter acknowledgement_ms : Float64?
    getter first_progress_ms : Float64?
    getter projection_read_p95_ms : Float64?
    getter max_unyielded_ms : Float64?

    def initialize(
      @domain_run_id : String,
      @evidence_items : Int32,
      @durable_events : Int32,
      @events_per_evidence : Float64,
      @annotations : Int32,
      @max_annotations_for_one_evidence : Int32,
      @behavior_firings : Int32,
      @behavior_firings_per_evidence : Float64,
      @provider_calls : Int32,
      @artifact_bytes : Int32,
      @max_queue_depth : Int32? = nil,
      @acknowledgement_ms : Float64? = nil,
      @first_progress_ms : Float64? = nil,
      @projection_read_p95_ms : Float64? = nil,
      @max_unyielded_ms : Float64? = nil,
    )
    end
  end

  # Evidence objects whose normalized_metadata names this connector run.
  def self._run_evidence(graph : Chronicle::GraphProjection, domain_run_id : String) : Array(Chronicle::GraphObject)
    graph.objects(type: "activity_evidence").select do |obj|
      data = JSON.parse(obj.data)
      metadata = data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
      metadata["connector_run_id"]?.try(&.as_s?) == domain_run_id
    end
  end

  # Active semantic annotations over the given evidence ids.
  def self._active_annotations(graph : Chronicle::GraphProjection, evidence_ids : Set(String)) : Array(Chronicle::GraphObject)
    graph.objects(type: "semantic_annotation").select do |obj|
      data = JSON.parse(obj.data)
      evidence_ids.includes?(data["evidence_id"]?.try(&.as_s?) || "") && data["status"]?.try(&.as_s?) == "active"
    end
  end

  # Log index of the domain run's object.created event.
  def self._event_start_index(graph : Chronicle::GraphProjection, domain_run_id : String) : Int32
    graph.events.each_with_index do |event, index|
      if event.type == "object.created" && JSON.parse(event.payload)["id"]?.try(&.as_s?) == domain_run_id
        return index
      end
    end
    raise Chronicle::Packs::PackError.new("domain run #{domain_run_id.inspect} has no object.created event")
  end

  # Retained artifact bytes for evidence in artifact replay mode.
  def self._artifact_bytes(graph : Chronicle::GraphProjection, evidence : Array(Chronicle::GraphObject), artifact_store_dir : String) : Int32
    refs = Set(String).new
    evidence.each do |obj|
      data = JSON.parse(obj.data)
      refs << (data["replay_payload_ref"]?.try(&.as_s?) || "") if data["replay_mode"]?.try(&.as_s?) == "artifact"
    end
    bytes = 0
    refs.each do |ref|
      path = ActivityNormalizer::Replay.artifact_path(artifact_store_dir, ref)
      bytes += File.size(path) if File.file?(path)
    end
    bytes
  end

  # Measure one connector run's conformance within the retained graph.
  def self.measure_connector_run(graph : Chronicle::GraphProjection, domain_run_id : String, artifact_store_dir : String, max_queue_depth : Int32? = nil, acknowledgement_ms : Float64? = nil, first_progress_ms : Float64? = nil, projection_read_p95_ms : Float64? = nil, max_unyielded_ms : Float64? = nil) : ConnectorOperationalMeasurement
    evidence = _run_evidence(graph, domain_run_id)
    evidence_ids = evidence.map(&.id).to_set
    annotations = _active_annotations(graph, evidence_ids)
    by_evidence = {} of String => Int32
    evidence_ids.each { |eid| by_evidence[eid] = 0 }
    annotations.each do |annotation_obj|
      annotation_data = JSON.parse(annotation_obj.data)
      evidence_id = annotation_data["evidence_id"]?.try(&.as_s?)
      next if evidence_id.nil? || !evidence_ids.includes?(evidence_id)

      by_evidence[evidence_id] = by_evidence[evidence_id] + 1
    end

    events = graph.events[_event_start_index(graph, domain_run_id)..]
    behavior_firings = events.count { |event| event.type.in?({"behavior.started", "relation_behavior.started"}) }
    provider_calls = graph.objects(type: "capability_call").count do |obj|
      data = JSON.parse(obj.data)
      metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
      gmail = metadata["gmail"]?.try(&.as_h) || {} of String => JSON::Any
      gmail["run_id"]?.try(&.as_s?) == domain_run_id
    end
    artifact_bytes = _artifact_bytes(graph, evidence, artifact_store_dir)

    divisor = evidence.size.zero? ? 1 : evidence.size
    ConnectorOperationalMeasurement.new(
      domain_run_id, evidence.size.to_i32, events.size.to_i32, events.size.to_f64 / divisor,
      annotations.size.to_i32, (by_evidence.values.max? || 0), behavior_firings, behavior_firings.to_f64 / divisor,
      provider_calls, artifact_bytes, max_queue_depth, acknowledgement_ms, first_progress_ms, projection_read_p95_ms, max_unyielded_ms,
    )
  end # List budget violations for a measurement against a policy.

  def self.operational_budget_violations(measurement : ConnectorOperationalMeasurement, policy : ConnectorOperationalPolicy? = nil) : Array(String)
    limits = policy || ConnectorOperationalPolicy.new(Policy::OPERATIONAL_POLICY_ID, "default")
    checks = [] of {String, Float64?, Float64}
    checks << {"evidence_items", measurement.evidence_items.to_f64, limits.fixture_items.to_f64}
    checks << {"events_per_evidence", measurement.events_per_evidence, limits.max_events_per_evidence.to_f64}
    checks << {"max_annotations_for_one_evidence", measurement.max_annotations_for_one_evidence.to_f64, limits.max_annotations_per_evidence.to_f64}
    checks << {"behavior_firings_per_evidence", measurement.behavior_firings_per_evidence, limits.max_behavior_firings_per_evidence.to_f64}
    checks << {"provider_calls", measurement.provider_calls.to_f64, limits.max_provider_calls.to_f64}
    checks << {"artifact_bytes", measurement.artifact_bytes.to_f64, limits.max_artifact_bytes.to_f64}
    checks << {"max_queue_depth", measurement.max_queue_depth.try(&.to_f64), limits.max_queue_depth.to_f64}
    checks << {"acknowledgement_ms", measurement.acknowledgement_ms, limits.ack_latency_ms.to_f64}
    checks << {"first_progress_ms", measurement.first_progress_ms, limits.first_progress_ms.to_f64}
    checks << {"projection_read_p95_ms", measurement.projection_read_p95_ms, limits.projection_read_p95_ms.to_f64}
    checks << {"max_unyielded_ms", measurement.max_unyielded_ms, limits.max_unyielded_ms.to_f64}

    violations = [] of String
    checks.each do |name, observed, limit|
      if observed.nil?
        violations << "#{name}: missing measurement"
      elsif observed > limit
        violations << "#{name}: #{observed.to_i64} > #{limit.to_i64}"
      end
    end
    violations
  end
end

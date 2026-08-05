require "json"

module Chronicle::Packs::ConnectorControl
  # Neutral connector control-plane materializations. Ported from upstream
  # packs/connector_control/object_types.py. Service/domain runs remain
  # authoritative; these objects are idempotent adapter outputs.

  # A service surface bound to one connector family.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connector_surface_binding", description: "A service surface bound to one connector family.")]
  struct ConnectorSurfaceBinding
    include JSON::Serializable

    getter binding_identity : String
    getter source_surface_id : String
    getter service : String
    getter account_ref : String
    getter family : String
    getter routes : Array(String) = [] of String
    getter active_route : String
    getter domain_run_type : String
    getter native_shape_version : Int32 = 1
    getter maintenance_mode : String = "none"
    getter? manual_refresh_available : Bool = false
    getter status : String = "active"
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      binding_identity : String, source_surface_id : String, service : String,
      account_ref : String, family : String, active_route : String, domain_run_type : String,
      routes : Array(String) = [] of String, native_shape_version : Int32 = 1,
      maintenance_mode : String = "none", manual_refresh_available : Bool = false,
      status : String = "active", metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @binding_identity = binding_identity
      @source_surface_id = source_surface_id
      @service = service
      @account_ref = account_ref
      @family = family
      @routes = routes
      @active_route = active_route
      @domain_run_type = domain_run_type
      @native_shape_version = native_shape_version
      @maintenance_mode = maintenance_mode
      @manual_refresh_available = manual_refresh_available
      @status = status
      @metadata = metadata
    end
  end

  # A summary of the run's stable cursor state.
  struct CursorSummary
    include JSON::Serializable

    getter position_kind : String?
    getter? has_position : Bool = false
    getter? advanced : Bool = false
    getter coverage : String = "unknown"

    def initialize(@position_kind : String? = nil, @has_position : Bool = false, @advanced : Bool = false, @coverage : String = "unknown")
    end
  end

  # A neutral adapter view of an authoritative domain run.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connector_run_observation", description: "A neutral adapter view of an authoritative domain run.")]
  struct ConnectorRunObservation
    include JSON::Serializable

    getter observation_identity : String
    getter domain_run_id : String
    getter source_surface_id : String
    getter service : String
    getter account_ref : String
    getter family : String
    getter route : String
    getter state : String
    getter health : String
    getter phase : String
    getter mode : String
    getter bounds : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter counts : Hash(String, Int64) = {} of String => Int64
    getter cursor : CursorSummary = CursorSummary.new
    getter attempt_event_ids : Array(String) = [] of String
    getter update_event_ids : Array(String) = [] of String
    getter terminal_event_ids : Array(String) = [] of String
    getter success_event_ids : Array(String) = [] of String
    getter maintenance_mode : String = "none"
    getter? manual_refresh_available : Bool = false
    getter? next_sync_available : Bool = false
    getter error_code : String?
    getter error : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      observation_identity : String, domain_run_id : String, source_surface_id : String,
      service : String, account_ref : String, family : String, route : String,
      state : String, health : String, phase : String, mode : String,
      bounds : Hash(String, JSON::Any) = {} of String => JSON::Any,
      counts : Hash(String, Int64) = {} of String => Int64,
      cursor : CursorSummary = CursorSummary.new,
      attempt_event_ids : Array(String) = [] of String,
      update_event_ids : Array(String) = [] of String,
      terminal_event_ids : Array(String) = [] of String,
      success_event_ids : Array(String) = [] of String,
      maintenance_mode : String = "none", manual_refresh_available : Bool = false,
      next_sync_available : Bool = false, error_code : String? = nil, error : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @observation_identity = observation_identity
      @domain_run_id = domain_run_id
      @source_surface_id = source_surface_id
      @service = service
      @account_ref = account_ref
      @family = family
      @route = route
      @state = state
      @health = health
      @phase = phase
      @mode = mode
      @bounds = bounds
      @counts = counts
      @cursor = cursor
      @attempt_event_ids = attempt_event_ids
      @update_event_ids = update_event_ids
      @terminal_event_ids = terminal_event_ids
      @success_event_ids = success_event_ids
      @maintenance_mode = maintenance_mode
      @manual_refresh_available = manual_refresh_available
      @next_sync_available = next_sync_available
      @error_code = error_code
      @error = error
      @metadata = metadata
    end
  end

  # Run-scoped counts and references for derived learning.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connector_learning_delta", description: "Run-scoped counts and references for derived learning.")]
  struct ConnectorLearningDelta
    include JSON::Serializable

    getter delta_identity : String
    getter domain_run_id : String
    getter source_surface_id : String
    getter service : String
    getter family : String
    getter status : String = "collecting"
    getter evidence : Hash(String, Int64) = {} of String => Int64
    getter annotation_coverage : Hash(String, Int64) = {} of String => Int64
    getter resolutions : Hash(String, Int64) = {} of String => Int64
    getter candidates : Hash(String, Hash(String, Int64)) = {} of String => Hash(String, Int64)
    getter failures : Int32 = 0
    getter exceptions : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter cost : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      delta_identity : String, domain_run_id : String, source_surface_id : String,
      service : String, family : String, status : String = "collecting",
      evidence : Hash(String, Int64) = {} of String => Int64,
      annotation_coverage : Hash(String, Int64) = {} of String => Int64,
      resolutions : Hash(String, Int64) = {} of String => Int64,
      candidates : Hash(String, Hash(String, Int64)) = {} of String => Hash(String, Int64),
      failures : Int32 = 0, exceptions : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      cost : Hash(String, JSON::Any) = {} of String => JSON::Any, refs : Array(String) = [] of String,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @delta_identity = delta_identity
      @domain_run_id = domain_run_id
      @source_surface_id = source_surface_id
      @service = service
      @family = family
      @status = status
      @evidence = evidence
      @annotation_coverage = annotation_coverage
      @resolutions = resolutions
      @candidates = candidates
      @failures = failures
      @exceptions = exceptions
      @cost = cost
      @refs = refs
      @metadata = metadata
    end
  end

  # A validated family-native read projection materialization.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connector_native_view", description: "A validated family-native read projection materialization.")]
  struct ConnectorNativeView
    include JSON::Serializable

    getter view_identity : String
    getter source_surface_id : String
    getter service : String
    getter family : String
    getter shape_version : Int32 = 1
    getter state : String
    getter data : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter refs : Array(String) = [] of String
    getter service_extensions : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter error : String?

    def initialize(
      view_identity : String, source_surface_id : String, service : String, family : String,
      state : String, data : Hash(String, JSON::Any) = {} of String => JSON::Any,
      shape_version : Int32 = 1, refs : Array(String) = [] of String,
      service_extensions : Hash(String, JSON::Any) = {} of String => JSON::Any,
      error : String? = nil,
    )
      @view_identity = view_identity
      @source_surface_id = source_surface_id
      @service = service
      @family = family
      @state = state
      @data = data
      @shape_version = shape_version
      @refs = refs
      @service_extensions = service_extensions
      @error = error
    end
  end

  # Versioned release budgets for connector work.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connector_operational_policy", description: "Versioned release budgets for connector work.")]
  struct ConnectorOperationalPolicy
    include JSON::Serializable

    getter policy_identity : String
    getter version : Int32 = 1
    getter status : String = "active"
    getter fixture_items : Int32 = 250
    getter ack_latency_ms : Int32 = 1_000
    getter first_progress_ms : Int32 = 2_000
    getter projection_read_p95_ms : Int32 = 500
    getter max_unyielded_ms : Int32 = 500
    getter max_events_per_evidence : Int32 = 100
    getter max_annotations_per_evidence : Int32 = 20
    getter max_behavior_firings_per_evidence : Int32 = 25
    getter max_provider_calls : Int32 = 10
    getter max_artifact_bytes : Int32 = 64 * 1024 * 1024
    getter max_queue_depth : Int32 = 5_000
    getter rationale : String

    def initialize(
      policy_identity : String, rationale : String, version : Int32 = 1,
      status : String = "active", fixture_items : Int32 = 250, ack_latency_ms : Int32 = 1_000,
      first_progress_ms : Int32 = 2_000, projection_read_p95_ms : Int32 = 500,
      max_unyielded_ms : Int32 = 500, max_events_per_evidence : Int32 = 100,
      max_annotations_per_evidence : Int32 = 20, max_behavior_firings_per_evidence : Int32 = 25,
      max_provider_calls : Int32 = 10, max_artifact_bytes : Int32 = 64 * 1024 * 1024,
      max_queue_depth : Int32 = 5_000,
    )
      @policy_identity = policy_identity
      @version = version
      @status = status
      @fixture_items = fixture_items
      @ack_latency_ms = ack_latency_ms
      @first_progress_ms = first_progress_ms
      @projection_read_p95_ms = projection_read_p95_ms
      @max_unyielded_ms = max_unyielded_ms
      @max_events_per_evidence = max_events_per_evidence
      @max_annotations_per_evidence = max_annotations_per_evidence
      @max_behavior_firings_per_evidence = max_behavior_firings_per_evidence
      @max_provider_calls = max_provider_calls
      @max_artifact_bytes = max_artifact_bytes
      @max_queue_depth = max_queue_depth
      @rationale = rationale
    end
  end

  # A provider-neutral owner request for bounded connector maintenance.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connector_maintenance_request", description: "A provider-neutral owner request for bounded connector maintenance.")]
  struct ConnectorMaintenanceRequest
    include JSON::Serializable

    getter request_identity : String
    getter source_surface_id : String
    getter service : String
    getter account_ref : String
    getter kind : String = "manual_refresh"
    getter requested_by : String
    getter status : String = "proposed"
    getter domain_run_id : String?
    getter error : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      request_identity : String, source_surface_id : String, service : String,
      account_ref : String, requested_by : String, kind : String = "manual_refresh",
      status : String = "proposed", domain_run_id : String? = nil, error : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @request_identity = request_identity
      @source_surface_id = source_surface_id
      @service = service
      @account_ref = account_ref
      @kind = kind
      @requested_by = requested_by
      @status = status
      @domain_run_id = domain_run_id
      @error = error
      @metadata = metadata
    end
  end
end

require "json"

module Chronicle::Packs::Usage
  # Neutral connection, coverage, settlement, and activity fact schemas.
  # Ported from upstream packs/usage/object_types.py.

  # Stable cursor state owned by a connection surface.
  struct CursorState
    include JSON::Serializable

    getter oldest_ingested_ref : String?
    getter newest_ingested_ref : String?
    getter watermark_ref : String?
    getter cursor_version : Int32 = 1

    def initialize(@oldest_ingested_ref : String? = nil, @newest_ingested_ref : String? = nil, @watermark_ref : String? = nil, @cursor_version : Int32 = 1)
    end
  end

  # One provider-neutral connected source surface and its current projection.
  @[Chronicle::Packs::Annotations::ObjectType(name: "connection_surface", description: "A provider-neutral connected source surface.")]
  struct ConnectionSurface
    include JSON::Serializable

    getter surface_id : String
    getter category : Chronicle::Packs::SourceCategory
    getter provider : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter path : Chronicle::Packs::ConnectionPath
    getter adapter : String?
    getter acquisition_mode : String = "snapshot"
    getter status : Chronicle::Packs::SurfaceStatus = Chronicle::Packs::SurfaceStatus::Connected
    getter privacy_scope : String = "source"
    getter cursor_state : CursorState = CursorState.new
    getter? is_fixture : Bool = false
    getter events_seen : Int32 = 0
    getter unique_evidence_count : Int32 = 0
    getter first_seen : String?
    getter last_seen : String?
    getter gate_id : String = "usage.category.default"
    getter gate_version : Int32 = 1
    getter settled_by : Array(String) = [] of String
    getter settled_event_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      surface_id : String, category : Chronicle::Packs::SourceCategory, path : Chronicle::Packs::ConnectionPath,
      provider : Hash(String, JSON::Any) = {} of String => JSON::Any,
      adapter : String? = nil, acquisition_mode : String = "snapshot",
      status : Chronicle::Packs::SurfaceStatus = Chronicle::Packs::SurfaceStatus::Connected, privacy_scope : String = "source",
      cursor_state : CursorState = CursorState.new, is_fixture : Bool = false,
      events_seen : Int32 = 0, unique_evidence_count : Int32 = 0,
      first_seen : String? = nil, last_seen : String? = nil,
      gate_id : String = "usage.category.default", gate_version : Int32 = 1,
      settled_by : Array(String) = [] of String, settled_event_id : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @surface_id = surface_id
      @category = category
      @provider = provider
      @path = path
      @adapter = adapter
      @acquisition_mode = acquisition_mode
      @status = status
      @privacy_scope = privacy_scope
      @cursor_state = cursor_state
      @is_fixture = is_fixture
      @events_seen = events_seen
      @unique_evidence_count = unique_evidence_count
      @first_seen = first_seen
      @last_seen = last_seen
      @gate_id = gate_id
      @gate_version = gate_version
      @settled_by = settled_by
      @settled_event_id = settled_event_id
      @metadata = metadata
    end
  end

  # Connector-authored request; Usage alone mints the canonical surface.
  @[Chronicle::Packs::Annotations::ObjectType(name: "source_connection_request", description: "A connector request for Usage to mint one canonical surface.")]
  struct SourceConnectionRequest
    include JSON::Serializable

    getter request_identity : String
    getter surface_id : String
    getter category : Chronicle::Packs::SourceCategory
    getter provider : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter path : Chronicle::Packs::ConnectionPath
    getter privacy_scope : String = "account"
    getter adapter : String?
    getter acquisition_mode : String = "backfill"
    getter status : String = "proposed"
    getter surface_object_id : String?
    getter error : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # An immutable named/versioned settlement definition.
  @[Chronicle::Packs::Annotations::ObjectType(name: "settling_gate", description: "An immutable named and versioned settlement definition.")]
  struct SettlingGate
    include JSON::Serializable

    getter definition_identity : String
    getter gate_id : String
    getter gate_version : Int32
    getter category : String?
    getter min_unique_events : Int32 = 25
    getter min_coverage_days : Int32 = 3
    getter? allow_either : Bool = true
    getter? active : Bool = true

    def initialize(
      definition_identity : String, gate_id : String, gate_version : Int32,
      category : String? = nil, min_unique_events : Int32 = 25,
      min_coverage_days : Int32 = 3, allow_either : Bool = true, active : Bool = true,
    )
      @definition_identity = definition_identity
      @gate_id = gate_id
      @gate_version = gate_version
      @category = category
      @min_unique_events = min_unique_events
      @min_coverage_days = min_coverage_days
      @allow_either = allow_either
      @active = active
    end
  end

  # Usage's current-revision index of a normalizer-owned logical identity.
  @[Chronicle::Packs::Annotations::ObjectType(name: "usage_evidence", description: "A projection keyed by normalizer-owned evidence identity.")]
  struct UsageEvidence
    include JSON::Serializable

    getter evidence_identity : String
    getter evidence_id : String
    getter revision_id : String
    getter revision_number : Int32
    getter source_surface_id : String
    getter source_category : Chronicle::Packs::SourceCategory
    getter connection_path : String
    getter source_ref : String
    getter provider_time : String?
    getter importer_id : String
    getter importer_version : String
    getter? is_fixture : Bool = false
    getter? qualifying : Bool = false
    getter? invalidated : Bool = false
    getter first_ingested_event_id : String
    getter last_ingested_event_id : String
    getter revision_count : Int32 = 1

    def initialize(
      evidence_identity : String, evidence_id : String, revision_id : String,
      revision_number : Int32, source_surface_id : String, source_category : Chronicle::Packs::SourceCategory,
      connection_path : String, source_ref : String, importer_id : String,
      importer_version : String, first_ingested_event_id : String,
      last_ingested_event_id : String, provider_time : String? = nil,
      is_fixture : Bool = false, qualifying : Bool = false, invalidated : Bool = false,
      revision_count : Int32 = 1,
    )
      @evidence_identity = evidence_identity
      @evidence_id = evidence_id
      @revision_id = revision_id
      @revision_number = revision_number
      @source_surface_id = source_surface_id
      @source_category = source_category
      @connection_path = connection_path
      @source_ref = source_ref
      @provider_time = provider_time
      @importer_id = importer_id
      @importer_version = importer_version
      @is_fixture = is_fixture
      @qualifying = qualifying
      @invalidated = invalidated
      @first_ingested_event_id = first_ingested_event_id
      @last_ingested_event_id = last_ingested_event_id
      @revision_count = revision_count
    end
  end

  # Historical first pass for one surface and immutable gate version.
  @[Chronicle::Packs::Annotations::ObjectType(name: "settlement_record", description: "A surface's historical first pass of one gate version.")]
  struct SettlementRecord
    include JSON::Serializable

    getter settlement_identity : String
    getter source_surface_id : String
    getter source_category : Chronicle::Packs::SourceCategory
    getter gate_id : String
    getter gate_version : Int32
    getter unique_evidence_count : Int32
    getter coverage_days : Int32
    getter coverage_start : String?
    getter coverage_end : String?
    getter passed_thresholds : Array(String)
    getter source_settled_event_id : String
    getter evaluated_at_event_id : String

    def initialize(
      settlement_identity : String, source_surface_id : String, source_category : Chronicle::Packs::SourceCategory,
      gate_id : String, gate_version : Int32, unique_evidence_count : Int32,
      coverage_days : Int32, coverage_start : String?, coverage_end : String?,
      passed_thresholds : Array(String), source_settled_event_id : String,
      evaluated_at_event_id : String,
    )
      @settlement_identity = settlement_identity
      @source_surface_id = source_surface_id
      @source_category = source_category
      @gate_id = gate_id
      @gate_version = gate_version
      @unique_evidence_count = unique_evidence_count
      @coverage_days = coverage_days
      @coverage_start = coverage_start
      @coverage_end = coverage_end
      @passed_thresholds = passed_thresholds
      @source_settled_event_id = source_settled_event_id
      @evaluated_at_event_id = evaluated_at_event_id
    end
  end

  # One idempotent interaction observation attributable to a surface.
  @[Chronicle::Packs::Annotations::ObjectType(name: "usage_record", description: "An idempotent interaction observation.")]
  struct UsageRecord
    include JSON::Serializable

    getter usage_identity : String
    getter source_surface_id : String
    getter source_category : Chronicle::Packs::SourceCategory
    getter interaction_type : String
    getter evidence_identity : String?
    getter provider_time : String?
    getter count : Int32 = 1
    getter? is_fixture : Bool = false
    getter source_provenance : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      usage_identity : String, source_surface_id : String, source_category : Chronicle::Packs::SourceCategory,
      interaction_type : String, evidence_identity : String? = nil,
      provider_time : String? = nil, count : Int32 = 1, is_fixture : Bool = false,
      source_provenance : Hash(String, JSON::Any) = {} of String => JSON::Any,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @usage_identity = usage_identity
      @source_surface_id = source_surface_id
      @source_category = source_category
      @interaction_type = interaction_type
      @evidence_identity = evidence_identity
      @provider_time = provider_time
      @count = count
      @is_fixture = is_fixture
      @source_provenance = source_provenance
      @metadata = metadata
    end
  end

  # A fail-closed projection error with the offending event identity.
  @[Chronicle::Packs::Annotations::ObjectType(name: "usage_projection_failure", description: "A fail-closed observational projection error.")]
  struct UsageProjectionFailure
    include JSON::Serializable

    getter event_id : String
    getter source_surface_id : String?
    getter evidence_identity : String?
    getter error_code : String
    getter message : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      event_id : String, error_code : String, message : String,
      source_surface_id : String? = nil, evidence_identity : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @event_id = event_id
      @source_surface_id = source_surface_id
      @evidence_identity = evidence_identity
      @error_code = error_code
      @message = message
      @metadata = metadata
    end
  end
end

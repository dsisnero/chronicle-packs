require "json"

module Chronicle::Packs::ActivityNormalizer
  # Provider-neutral ingestion, evidence, replay, and candidate schemas.
  # Ported from upstream packs/activity_normalizer/object_types.py. All
  # types are immutable JSON::Serializable structs; unknown JSON keys are
  # tolerated (upstream forbids extras via pydantic extra="forbid").
  # ReplayMode/SourceCategory/ConnectionPath are modeled as plain String.

  # One fully identified provider/file/export unit emitted by an importer.
  @[Chronicle::Packs::Annotations::ObjectType(name: "acquired_item", description: "A strict importer-emitted acquisition unit.")]
  struct AcquiredItem
    include JSON::Serializable

    getter source_surface_id : String
    getter provider_item_id : String?
    getter dedup_key : String
    getter source_ref : String
    getter source_hash : String?
    getter provider_time : String?
    getter replay_mode : Chronicle::Packs::ReplayMode
    getter replay_payload_ref : String
    getter replay_payload_hash : String
    getter media_type : String
    getter importer_id : String
    getter importer_version : String
  end

  # The exact normalized-content handoff paired with an acquired item.
  @[Chronicle::Packs::Annotations::ObjectType(name: "acquired_content", description: "Normalized content paired with an acquired item.")]
  struct AcquiredContent
    include JSON::Serializable

    getter acquired_item_id : String
    getter normalized_content : String
    getter normalized_metadata : Hash(String, JSON::Any)
    getter source_category : Chronicle::Packs::SourceCategory
    getter connection_path : Chronicle::Packs::ConnectionPath
    getter? is_fixture : Bool
  end

  # Stable bidirectional progress for snapshots, backfills, and live feeds.
  @[Chronicle::Packs::Annotations::ObjectType(name: "backfill_cursor", description: "Stable source backfill progress without offsets.")]
  struct BackfillCursor
    include JSON::Serializable

    getter source_surface_id : String
    getter oldest_ingested_ref : String?
    getter newest_ingested_ref : String?
    getter watermark_ref : String?
    getter cursor_version : Int32 = 1
  end

  # Provider tombstone handoff; the normalizer owns evidence invalidation.
  @[Chronicle::Packs::Annotations::ObjectType(name: "evidence_invalidation_request", description: "A provider/owner tombstone fulfilled by the identity-owning normalizer.")]
  struct EvidenceInvalidationRequest
    include JSON::Serializable

    getter request_identity : String
    getter source_surface_id : String
    getter provider_item_id : String?
    getter evidence_identity : String?
    getter reason : String
    getter status : String = "proposed"
    getter invalidated_evidence_ids : Array(String) = [] of String
    getter error : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # One immutable revision of a logical, provider-neutral evidence identity.
  @[Chronicle::Packs::Annotations::ObjectType(name: "activity_evidence", description: "A provider-neutral evidence revision.")]
  struct ActivityEvidence
    include JSON::Serializable

    getter evidence_identity : String
    getter revision_id : String
    getter revision_number : Int32
    getter status : String = "current"
    getter acquired_item_id : String
    getter acquired_content_id : String
    getter source_surface_id : String
    getter provider_item_id : String?
    getter dedup_key : String
    getter source_ref : String
    getter source_hash : String?
    getter content_hash : String
    getter provider_time : String?
    getter replay_mode : Chronicle::Packs::ReplayMode
    getter replay_payload_ref : String
    getter replay_payload_hash : String
    getter? replay_complete : Bool
    getter media_type : String
    getter encoding : String = "utf-8"
    getter retention_policy : String = "source_default"
    getter acquired_at_event_id : String
    getter normalized_content : String
    getter normalized_metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter source_category : Chronicle::Packs::SourceCategory
    getter connection_path : Chronicle::Packs::ConnectionPath
    getter importer_id : String
    getter importer_version : String
    getter? is_fixture : Bool = false
    getter supersedes_evidence_id : String?

    def initialize(
      evidence_identity : String, revision_id : String, revision_number : Int32,
      acquired_item_id : String, acquired_content_id : String,
      source_surface_id : String, dedup_key : String, source_ref : String,
      content_hash : String, replay_mode : Chronicle::Packs::ReplayMode,
      replay_payload_ref : String, replay_payload_hash : String,
      replay_complete : Bool, media_type : String, acquired_at_event_id : String,
      normalized_content : String, source_category : Chronicle::Packs::SourceCategory,
      connection_path : Chronicle::Packs::ConnectionPath, importer_id : String, importer_version : String,
      status : String = "current", provider_item_id : String? = nil,
      source_hash : String? = nil, provider_time : String? = nil,
      encoding : String = "utf-8", retention_policy : String = "source_default",
      normalized_metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      is_fixture : Bool = false, supersedes_evidence_id : String? = nil,
    )
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @revision_number = revision_number
      @status = status
      @acquired_item_id = acquired_item_id
      @acquired_content_id = acquired_content_id
      @source_surface_id = source_surface_id
      @provider_item_id = provider_item_id
      @dedup_key = dedup_key
      @source_ref = source_ref
      @source_hash = source_hash
      @content_hash = content_hash
      @provider_time = provider_time
      @replay_mode = replay_mode
      @replay_payload_ref = replay_payload_ref
      @replay_payload_hash = replay_payload_hash
      @replay_complete = replay_complete
      @media_type = media_type
      @encoding = encoding
      @retention_policy = retention_policy
      @acquired_at_event_id = acquired_at_event_id
      @normalized_content = normalized_content
      @normalized_metadata = normalized_metadata
      @source_category = source_category
      @connection_path = connection_path
      @importer_id = importer_id
      @importer_version = importer_version
      @is_fixture = is_fixture
      @supersedes_evidence_id = supersedes_evidence_id
    end
  end

  # A recorded, non-partial failure at one ingestion pipeline stage.
  @[Chronicle::Packs::Annotations::ObjectType(name: "ingestion_failure", description: "A recorded ingestion pipeline failure.")]
  struct IngestionFailure
    include JSON::Serializable

    getter source_surface_id : String?
    getter acquired_item_id : String?
    getter source_ref : String?
    getter stage : String
    getter error_code : String
    getter message : String
    getter importer_id : String?
    getter importer_version : String?
    getter extractor_id : String?
    getter extractor_version : String?
    getter? recoverable : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      stage : String, error_code : String, message : String,
      source_surface_id : String? = nil, acquired_item_id : String? = nil,
      source_ref : String? = nil, importer_id : String? = nil,
      importer_version : String? = nil, extractor_id : String? = nil,
      extractor_version : String? = nil, recoverable : Bool = false,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @stage = stage
      @error_code = error_code
      @message = message
      @source_surface_id = source_surface_id
      @acquired_item_id = acquired_item_id
      @source_ref = source_ref
      @importer_id = importer_id
      @importer_version = importer_version
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @recoverable = recoverable
      @metadata = metadata
    end
  end

  # One idempotent extractor/configuration run over one evidence revision.
  @[Chronicle::Packs::Annotations::ObjectType(name: "extraction_record", description: "A versioned deterministic extraction run.")]
  struct ExtractionRecord
    include JSON::Serializable

    getter extraction_identity : String
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String
    getter input_content_hash : String
    getter input_replay_payload_hash : String
    getter candidate_ids : Array(String) = [] of String
    getter candidate_types : Array(String) = [] of String
    getter status : String = "completed"
    getter? replayed : Bool = false
    getter? replay_verified : Bool = false
    getter error : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      extraction_identity : String, evidence_id : String, evidence_identity : String,
      revision_id : String, extractor_id : String, extractor_version : String,
      extraction_config_id : String, input_content_hash : String,
      input_replay_payload_hash : String, replayed : Bool = false,
      replay_verified : Bool = false,
    )
      @extraction_identity = extraction_identity
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @extraction_config_id = extraction_config_id
      @input_content_hash = input_content_hash
      @input_replay_payload_hash = input_replay_payload_hash
      @replayed = replayed
      @replay_verified = replay_verified
    end
  end

  # Current eligibility state for an extractor version/configuration.
  @[Chronicle::Packs::Annotations::ObjectType(name: "extractor_version_state", description: "Eligibility of an extractor version.")]
  struct ExtractorVersionState
    include JSON::Serializable

    getter state_identity : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String?
    getter status : String = "enabled"
    getter reason : String = ""
    getter changed_at_event_id : String?
  end

  struct PreferenceCandidate
    include JSON::Serializable

    getter candidate_identity : String
    getter text : String
    getter confidence : Float64 = 0.7
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter extraction_record_id : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String
    getter status : String = "candidate"
    getter invalidation_reason : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter preference : String

    def initialize(
      candidate_identity : String, text : String, evidence_id : String,
      evidence_identity : String, revision_id : String, extraction_record_id : String,
      extractor_id : String, extractor_version : String, extraction_config_id : String,
      confidence : Float64 = 0.7, status : String = "candidate",
      invalidation_reason : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      preference : String = "",
    )
      @candidate_identity = candidate_identity
      @text = text
      @confidence = confidence
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @extraction_record_id = extraction_record_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @extraction_config_id = extraction_config_id
      @status = status
      @invalidation_reason = invalidation_reason
      @metadata = metadata
      @preference = preference
    end
  end

  @[Chronicle::Packs::Annotations::ObjectType(name: "task_candidate", description: "A task proposed from evidence.")]
  struct TaskCandidate
    include JSON::Serializable

    getter candidate_identity : String
    getter text : String
    getter confidence : Float64 = 0.7
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter extraction_record_id : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String
    getter status : String = "candidate"
    getter invalidation_reason : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter title : String
    getter description : String = ""

    def initialize(
      candidate_identity : String, text : String, evidence_id : String,
      evidence_identity : String, revision_id : String, extraction_record_id : String,
      extractor_id : String, extractor_version : String, extraction_config_id : String,
      confidence : Float64 = 0.7, status : String = "candidate",
      invalidation_reason : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      title : String = "", description : String = "",
    )
      @candidate_identity = candidate_identity
      @text = text
      @confidence = confidence
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @extraction_record_id = extraction_record_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @extraction_config_id = extraction_config_id
      @status = status
      @invalidation_reason = invalidation_reason
      @metadata = metadata
      @title = title
      @description = description
    end
  end

  @[Chronicle::Packs::Annotations::ObjectType(name: "profile_candidate", description: "A profile fact proposed from evidence.")]
  struct ProfileCandidate
    include JSON::Serializable

    getter candidate_identity : String
    getter text : String
    getter confidence : Float64 = 0.7
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter extraction_record_id : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String
    getter status : String = "candidate"
    getter invalidation_reason : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter attribute : String = "profile_statement"
    getter value : String

    def initialize(
      candidate_identity : String, text : String, evidence_id : String,
      evidence_identity : String, revision_id : String, extraction_record_id : String,
      extractor_id : String, extractor_version : String, extraction_config_id : String,
      confidence : Float64 = 0.7, status : String = "candidate",
      invalidation_reason : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      attribute : String = "profile_statement", value : String = "",
    )
      @candidate_identity = candidate_identity
      @text = text
      @confidence = confidence
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @extraction_record_id = extraction_record_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @extraction_config_id = extraction_config_id
      @status = status
      @invalidation_reason = invalidation_reason
      @metadata = metadata
      @attribute = attribute
      @value = value
    end
  end

  @[Chronicle::Packs::Annotations::ObjectType(name: "skill_candidate", description: "A learned behavior proposed from evidence.")]
  struct SkillCandidate
    include JSON::Serializable

    getter candidate_identity : String
    getter text : String
    getter confidence : Float64 = 0.7
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter extraction_record_id : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String
    getter status : String = "candidate"
    getter invalidation_reason : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter name : String
    getter description : String = ""

    def initialize(
      candidate_identity : String, text : String, evidence_id : String,
      evidence_identity : String, revision_id : String, extraction_record_id : String,
      extractor_id : String, extractor_version : String, extraction_config_id : String,
      confidence : Float64 = 0.7, status : String = "candidate",
      invalidation_reason : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      name : String = "", description : String = "",
    )
      @candidate_identity = candidate_identity
      @text = text
      @confidence = confidence
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @extraction_record_id = extraction_record_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @extraction_config_id = extraction_config_id
      @status = status
      @invalidation_reason = invalidation_reason
      @metadata = metadata
      @name = name
      @description = description
    end
  end

  @[Chronicle::Packs::Annotations::ObjectType(name: "eval_candidate", description: "An evaluation signal proposed from evidence.")]
  struct EvalCandidate
    include JSON::Serializable

    getter candidate_identity : String
    getter text : String
    getter confidence : Float64 = 0.7
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter extraction_record_id : String
    getter extractor_id : String
    getter extractor_version : String
    getter extraction_config_id : String
    getter status : String = "candidate"
    getter invalidation_reason : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter subject : String = "source_activity"
    getter judgment : String

    def initialize(
      candidate_identity : String, text : String, evidence_id : String,
      evidence_identity : String, revision_id : String, extraction_record_id : String,
      extractor_id : String, extractor_version : String, extraction_config_id : String,
      confidence : Float64 = 0.7, status : String = "candidate",
      invalidation_reason : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      subject : String = "source_activity", judgment : String = "",
    )
      @candidate_identity = candidate_identity
      @text = text
      @confidence = confidence
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @extraction_record_id = extraction_record_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @extraction_config_id = extraction_config_id
      @status = status
      @invalidation_reason = invalidation_reason
      @metadata = metadata
      @subject = subject
      @judgment = judgment
    end
  end
end

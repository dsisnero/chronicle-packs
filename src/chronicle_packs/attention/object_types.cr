require "json"

module Chronicle::Packs::Attention
  # Attention object types. Ported from upstream packs/attention/object_types.py.
  # Upstream uses Pydantic strict models (extra fields forbidden); the
  # Crystal structs parse JSON::Serializable (extra fields ignored).

  # One semantic user/system signal, never raw UI telemetry.
  @[Chronicle::Packs::Annotations::ObjectType(name: "attention_observation")]
  struct AttentionObservation
    include JSON::Serializable

    getter observation_id : String
    getter subject_ref : String
    getter subject_kind : String = "object"
    getter signal_type : String
    getter strength_milli : Int32 = 1_000
    getter context_key : String = "global"
    getter objective_ref : String? = nil
    getter horizon_key : String = "current"
    getter session_id : String?
    getter opportunity_id : String?
    getter active_ms : Int32?
    getter occurred_at : String?
    getter source : String = "client"
    getter? explicit : Bool = false
    getter evidence_refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @observation_id : String,
      @subject_ref : String,
      @signal_type : String,
      @subject_kind : String = "object",
      @strength_milli : Int32 = 1000,
      @context_key : String = "global",
      @objective_ref : String? = nil,
      @horizon_key : String = "current",
      @session_id : String? = nil,
      @opportunity_id : String? = nil,
      @active_ms : Int32? = nil,
      @occurred_at : String? = nil,
      @source : String = "client",
      @explicit : Bool = false,
      @evidence_refs : Array(String) = [] of String,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A bounded flush of semantic observations from one client session.
  @[Chronicle::Packs::Annotations::ObjectType(name: "interaction_batch")]
  struct InteractionBatch
    include JSON::Serializable

    getter batch_id : String
    getter session_id : String
    getter batch_sequence : Int32
    getter client_id : String
    getter client_version : String = ""
    getter started_at : String?
    getter ended_at : String?
    getter active_duration_ms : Int32 = 0
    getter observation_ids : Array(String) = [] of String
    getter raw_event_count : Int32 = 0
    getter flush_reason : String = "manual"
    getter privacy_mode : String = "semantic_only"
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @batch_id : String,
      @session_id : String,
      @batch_sequence : Int32,
      @client_id : String,
      @client_version : String = "",
      @started_at : String? = nil,
      @ended_at : String? = nil,
      @active_duration_ms : Int32 = 0,
      @observation_ids : Array(String) = [] of String,
      @raw_event_count : Int32 = 0,
      @flush_reason : String = "manual",
      @privacy_mode : String = "semantic_only",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Current subject-scoped salience prediction and its complete evidence.
  @[Chronicle::Packs::Annotations::ObjectType(name: "importance_vector")]
  struct ImportanceVector
    include JSON::Serializable

    getter vector_key : String
    getter subject_ref : String
    getter subject_kind : String = "object"
    getter context_key : String = "global"
    getter objective_ref : String? = nil
    getter horizon_key : String = "current"
    getter score_milli : Int32
    getter confidence_milli : Int32
    getter priority_band : String
    getter support_milli : Int32 = 0
    getter oppose_milli : Int32 = 0
    getter features : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter observation_ids : Array(String) = [] of String
    getter policy_id : String
    getter policy_version : Int32
    getter latest_observation_id : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @vector_key : String,
      @subject_ref : String,
      @subject_kind : String,
      @context_key : String,
      @objective_ref : String?,
      @horizon_key : String,
      @score_milli : Int32,
      @confidence_milli : Int32,
      @priority_band : String,
      @support_milli : Int32,
      @oppose_milli : Int32,
      @features : Hash(String, JSON::Any),
      @observation_ids : Array(String),
      @policy_id : String,
      @policy_version : Int32,
      @latest_observation_id : String,
      @metadata : Hash(String, JSON::Any),
    )
    end
  end

  # Domain-scoped credibility prediction learned from canonical outcomes.
  @[Chronicle::Packs::Annotations::ObjectType(name: "source_trust_vector")]
  struct SourceTrustVector
    include JSON::Serializable

    getter vector_key : String
    getter source_ref : String
    getter source_kind : String
    getter domain : String
    getter query_scope : String
    getter score_milli : Int32
    getter confidence_milli : Int32
    getter verdict : String
    getter support_milli : Int32 = 0
    getter challenge_milli : Int32 = 0
    getter features : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter outcome_event_ids : Array(String) = [] of String
    getter policy_id : String
    getter policy_version : Int32
    getter latest_outcome_event_id : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @vector_key : String,
      @source_ref : String,
      @source_kind : String,
      @domain : String,
      @query_scope : String,
      @score_milli : Int32,
      @confidence_milli : Int32,
      @verdict : String,
      @support_milli : Int32,
      @challenge_milli : Int32,
      @features : Hash(String, JSON::Any),
      @outcome_event_ids : Array(String),
      @policy_id : String,
      @policy_version : Int32,
      @latest_outcome_event_id : String,
      @metadata : Hash(String, JSON::Any),
    )
    end
  end
end

require "json"

module Chronicle::Packs::EvalOutcome
  # Eval Outcome object types. Ported from upstream
  # packs/eval_outcome/object_types.py.

  # The outcome-kind tallies owned by an artifact reliability projection.
  struct ReliabilityTallies
    include JSON::Serializable

    getter helped : Int32 = 0
    getter hurt : Int32 = 0
    getter neutral : Int32 = 0
    getter contradicted : Int32 = 0
    getter stale : Int32 = 0
    getter superseded : Int32 = 0

    def initialize(
      @helped : Int32 = 0,
      @hurt : Int32 = 0,
      @neutral : Int32 = 0,
      @contradicted : Int32 = 0,
      @stale : Int32 = 0,
      @superseded : Int32 = 0,
    )
    end
  end

  # One canonical terminal or maintenance outcome with subject trace.
  @[Chronicle::Packs::Annotations::ObjectType(name: "outcome_record")]
  struct OutcomeRecord
    include JSON::Serializable

    getter outcome_event_id : String
    getter outcome_type : String
    getter evaluation_id : String? = nil
    getter usage_id : String? = nil
    getter artifact_id : String
    getter artifact_type : String
    getter artifact_version : String? = nil
    getter evidence_revision_id : String? = nil
    getter superseding_version : String? = nil
    getter contribution_key : String
    getter rationale : String = ""
    getter actor : String
    getter source_context : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter? is_fixture : Bool = false

    def initialize(
      @outcome_event_id : String,
      @outcome_type : String,
      @artifact_id : String,
      @artifact_type : String,
      @contribution_key : String,
      @actor : String,
      @evaluation_id : String? = nil,
      @usage_id : String? = nil,
      @artifact_version : String? = nil,
      @evidence_revision_id : String? = nil,
      @superseding_version : String? = nil,
      @rationale : String = "",
      @source_context : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @is_fixture : Bool = false,
    )
    end
  end

  # Current recency-aware reliability owned by one artifact version.
  @[Chronicle::Packs::Annotations::ObjectType(name: "artifact_reliability")]
  struct ArtifactReliability
    include JSON::Serializable

    getter artifact_id : String
    getter artifact_type : String
    getter artifact_version : String? = nil
    getter tallies : ReliabilityTallies = ReliabilityTallies.new
    getter verdict : String = "weak"
    getter? eligible : Bool = true
    getter retrieval_multiplier : Float64 = 0.75
    getter latest_outcome_type : String
    getter latest_outcome_event_id : String
    getter latest_evaluation_id : String? = nil
    getter latest_usage_id : String? = nil
    getter evidence_event_ids : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @artifact_id : String,
      @artifact_type : String,
      @latest_outcome_type : String,
      @latest_outcome_event_id : String,
      @artifact_version : String? = nil,
      @tallies : ReliabilityTallies = ReliabilityTallies.new,
      @verdict : String = "weak",
      @eligible : Bool = true,
      @retrieval_multiplier : Float64 = 0.75,
      @latest_evaluation_id : String? = nil,
      @latest_usage_id : String? = nil,
      @evidence_event_ids : Array(String) = [] of String,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

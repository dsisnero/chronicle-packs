require "json"

module Chronicle::Packs::Skills
  # Skills object types. Ported from upstream packs/skills/object_types.py.
  # Versioned, provenance-backed learned skills with reversible lifecycle.

  # The neutral outcome tally on a skill artifact.
  struct OutcomeSummary
    include JSON::Serializable

    getter helped : Int32 = 0
    getter hurt : Int32 = 0
    getter neutral : Int32 = 0

    def initialize(@helped : Int32 = 0, @hurt : Int32 = 0, @neutral : Int32 = 0)
    end
  end

  # One recorded promotion (or re-promotion) in a skill's history.
  struct PromotionHistoryEntry
    include JSON::Serializable

    getter event_id : String?
    getter evidence_id : String?
    getter rationale : String?
    getter actor : String?
    getter prior_status : String?
    getter new_status : String?

    def initialize(
      @event_id : String? = nil,
      @evidence_id : String? = nil,
      @rationale : String? = nil,
      @actor : String? = nil,
      @prior_status : String? = nil,
      @new_status : String? = nil,
    )
    end
  end

  # One immutable definition version plus reversible lifecycle state.
  @[Chronicle::Packs::Annotations::ObjectType(name: "skill")]
  struct SkillArtifact
    include JSON::Serializable

    getter skill_id : String
    getter version_identity : String
    getter name : String
    getter version : String
    getter definition_hash : String
    getter description : String = ""
    getter trigger_conditions : Array(String) = [] of String
    getter required_capabilities : Array(String) = [] of String
    getter contraindications : Array(String) = [] of String
    getter source_evidence_refs : Array(String) = [] of String
    getter source_candidate_id : String? = nil
    getter status : String = "candidate"
    getter outcome_summary : OutcomeSummary = OutcomeSummary.new
    getter promotion_history : Array(PromotionHistoryEntry) = [] of PromotionHistoryEntry
    getter? definition_locked : Bool = false
    getter demotion_reason : String? = nil
    getter? is_fixture : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @skill_id : String,
      @version_identity : String,
      @name : String,
      @version : String,
      @definition_hash : String,
      @description : String = "",
      @trigger_conditions : Array(String) = [] of String,
      @required_capabilities : Array(String) = [] of String,
      @contraindications : Array(String) = [] of String,
      @source_evidence_refs : Array(String) = [] of String,
      @source_candidate_id : String? = nil,
      @status : String = "candidate",
      @outcome_summary : OutcomeSummary = OutcomeSummary.new,
      @promotion_history : Array(PromotionHistoryEntry) = [] of PromotionHistoryEntry,
      @definition_locked : Bool = false,
      @demotion_reason : String? = nil,
      @is_fixture : Bool = false,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # One idempotent invocation of an exact skill version.
  @[Chronicle::Packs::Annotations::ObjectType(name: "skill_usage")]
  struct SkillUsage
    include JSON::Serializable

    getter usage_id : String
    getter skill_id : String
    getter skill_version : String
    getter skill_version_id : String
    getter execution_ref : String
    getter execution_kind : String
    getter actor : String
    getter source_context : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter required_capabilities : Array(String) = [] of String
    getter capability_call_ids : Array(String) = [] of String
    getter used_event_id : String
    getter? is_fixture : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @usage_id : String,
      @skill_id : String,
      @skill_version : String,
      @skill_version_id : String,
      @execution_ref : String,
      @execution_kind : String,
      @actor : String,
      @source_context : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @required_capabilities : Array(String) = [] of String,
      @capability_call_ids : Array(String) = [] of String,
      @used_event_id : String = "behavior-emitted",
      @is_fixture : Bool = false,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Recorded proof considered by the promotion gate.
  @[Chronicle::Packs::Annotations::ObjectType(name: "skill_promotion_evidence")]
  struct SkillPromotionEvidence
    include JSON::Serializable

    getter evidence_id : String
    getter skill_version_id : String
    getter kind : String
    getter reference_ids : Array(String)
    getter? accepted : Bool = true
    getter rationale : String = ""
    getter actor : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @evidence_id : String,
      @skill_version_id : String,
      @kind : String,
      @reference_ids : Array(String),
      @accepted : Bool = true,
      @rationale : String = "",
      @actor : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Connects a usage to the Core evaluation that judged it.
  @[Chronicle::Packs::Annotations::ObjectType(name: "skill_evaluation_link")]
  struct SkillEvaluationLink
    include JSON::Serializable

    getter usage_id : String
    getter skill_version_id : String
    getter evaluation_id : String
    getter evaluated_event_id : String

    def initialize(@usage_id : String, @skill_version_id : String, @evaluation_id : String, @evaluated_event_id : String)
    end
  end
end

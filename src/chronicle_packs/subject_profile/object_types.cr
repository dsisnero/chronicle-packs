require "json"

module Chronicle::Packs::SubjectProfile
  # Subject Profile Pack object types. Ported from upstream
  # packs/subject_profile/object_types.py. Evidence-backed, explicitly
  # reviewed subject facts with contradiction and supersession lifecycles.

  # Closed Literal sets for the subject_profile surface (AGENTS.md: closed
  # string sets are enums; non-flags enums round-trip via the underscore
  # name).

  # SubjectFactVerdict.decision — upstream Literal["confirm", "reject",
  # "correct"].
  enum VerdictDecision
    Confirm
    Reject
    Correct
  end

  # SubjectFactVerdict.status — upstream Literal["proposed", "applied",
  # "failed"].
  enum VerdictStatus
    Proposed
    Applied
    Failed
  end

  # SubjectFact.status — upstream Literal["promoted", "contradicted",
  # "superseded", "forgotten"].
  enum FactStatus
    Promoted
    Contradicted
    Superseded
    Forgotten
  end

  # SubjectContradiction.status — upstream Literal["open", "resolved"].
  enum ContradictionStatus
    Open
    Resolved
  end

  # An explicit review decision over one profile candidate.
  @[Chronicle::Packs::Annotations::ObjectType(name: "subject_fact_verdict", description: "An explicit review decision over one profile candidate.")]
  struct SubjectFactVerdict
    include JSON::Serializable

    getter candidate_id : String
    getter subject_ref : String
    getter decision : VerdictDecision
    getter corrected_value : String? = nil
    getter decided_by : String = "owner"
    getter rationale : String = ""
    getter status : VerdictStatus = VerdictStatus::Proposed
    getter result_fact_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @candidate_id : String,
      @subject_ref : String,
      @decision : VerdictDecision,
      @corrected_value : String? = nil,
      @decided_by : String = "owner",
      @rationale : String = "",
      @status : VerdictStatus = VerdictStatus::Proposed,
      @result_fact_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A promoted, subject-scoped fact with exact evidence provenance.
  @[Chronicle::Packs::Annotations::ObjectType(name: "subject_fact", description: "A promoted, subject-scoped fact with exact evidence provenance.")]
  struct SubjectFact
    include JSON::Serializable

    getter fact_identity : String
    getter subject_ref : String
    getter attribute : String
    getter value : String
    getter text : String
    getter status : FactStatus = FactStatus::Promoted
    getter confidence : Float64 = 0.7
    getter trust : Float64 = 0.5
    getter candidate_id : String? = nil
    getter annotation_id : String? = nil
    getter evidence_id : String? = nil
    getter source_surface_id : String? = nil
    getter verdict_id : String? = nil
    getter supersedes_fact_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @fact_identity : String,
      @subject_ref : String,
      @attribute : String,
      @value : String,
      @text : String,
      @status : FactStatus = FactStatus::Promoted,
      @confidence : Float64 = 0.7,
      @trust : Float64 = 0.5,
      @candidate_id : String? = nil,
      @annotation_id : String? = nil,
      @evidence_id : String? = nil,
      @source_surface_id : String? = nil,
      @verdict_id : String? = nil,
      @supersedes_fact_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Conflicting promoted facts about one subject attribute.
  @[Chronicle::Packs::Annotations::ObjectType(name: "subject_contradiction", description: "Conflicting promoted facts about one subject attribute.")]
  struct SubjectContradiction
    include JSON::Serializable

    getter contradiction_identity : String
    getter subject_ref : String
    getter attribute : String
    getter fact_ids : Array(String)
    getter status : ContradictionStatus = ContradictionStatus::Open
    getter winning_fact_id : String? = nil
    getter rationale : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @contradiction_identity : String,
      @subject_ref : String,
      @attribute : String,
      @fact_ids : Array(String),
      @status : ContradictionStatus = ContradictionStatus::Open,
      @winning_fact_id : String? = nil,
      @rationale : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

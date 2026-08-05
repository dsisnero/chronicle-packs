require "json"

module Chronicle::Packs::MemoryGateway
  # Memory Gateway Pack object types. Ported from upstream
  # packs/memory_gateway/object_types.py. Core produces memory_candidates;
  # this pack decides what to keep, stores accepted items, and handles
  # retrieval.

  # Closed string-literal sets modeled as enums: non-flags enums serialize
  # as the member name via String#underscore, so to_json/from_json round-trip
  # to the exact upstream value.

  enum ReliabilityVerdict
    Supported
    Weak
    Harmful
    Stale
  end

  enum PromotionStatus
    Admitted
    Promoted
    Demoted
  end

  enum PromotionDirection
    Promote
    Demote
  end

  enum ProposalStatus
    Proposed
    Approved
    Rejected
  end

  enum ResolutionTier
    Evidence
    AnnotatedEvidence
    CompiledBelief
    LiveLookup
    None
  end

  # A durable memory item — an accepted memory_candidate.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_item", description: "A durable memory item — an accepted and stored memory_candidate.")]
  struct MemoryItem
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter text : String
    getter category : String?
    getter confidence : Float64 = 0.7
    getter source_ids : Array(String) = [] of String
    getter candidate_id : String?
    getter created_at : String?
    getter last_retrieved_at : String?
    getter retrieval_count : Int32 = 0
    getter subject_ref : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter reliability_verdict : ReliabilityVerdict = ReliabilityVerdict::Weak
    getter reliability_multiplier : Float64 = 1.0
    getter reliability_event_id : String?
    getter promotion_status : PromotionStatus = PromotionStatus::Admitted
    getter artifact_version : String = "1"
    getter promotion_history : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)

    def initialize(
      text : String, category : String? = nil, confidence : Float64 = 0.7,
      source_ids : Array(String) = [] of String, candidate_id : String? = nil,
      created_at : String? = nil, last_retrieved_at : String? = nil,
      retrieval_count : Int32 = 0, subject_ref : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      reliability_verdict : ReliabilityVerdict = ReliabilityVerdict::Weak, reliability_multiplier : Float64 = 1.0,
      reliability_event_id : String? = nil, promotion_status : PromotionStatus = PromotionStatus::Admitted,
      artifact_version : String = "1",
      promotion_history : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
    )
      @text = text
      @category = category
      @confidence = confidence
      @source_ids = source_ids
      @candidate_id = candidate_id
      @created_at = created_at
      @last_retrieved_at = last_retrieved_at
      @retrieval_count = retrieval_count
      @subject_ref = subject_ref
      @metadata = metadata
      @reliability_verdict = reliability_verdict
      @reliability_multiplier = reliability_multiplier
      @reliability_event_id = reliability_event_id
      @promotion_status = promotion_status
      @artifact_version = artifact_version
      @promotion_history = promotion_history
    end

    define_copy_with(text, category, confidence, source_ids, candidate_id, created_at, last_retrieved_at, retrieval_count, subject_ref, metadata, reliability_verdict, reliability_multiplier, reliability_event_id, promotion_status, artifact_version, promotion_history)
  end

  # A reliability-generated promote/demote proposal for one memory item.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_promotion_proposal", description: "A reliability-generated promote/demote proposal for a memory item version.")]
  struct MemoryPromotionProposal
    include JSON::Serializable

    getter proposal_id : String
    getter artifact_id : String
    getter artifact_version : String = "1"
    getter direction : PromotionDirection = PromotionDirection::Promote
    getter status : ProposalStatus = ProposalStatus::Proposed
    getter reliability_verdict : String = ""
    getter helped_outcomes : Int32 = 0
    getter evidence_event_ids : Array(String) = [] of String
    getter rule_id : String = ""
    getter rule_version : Int32 = 0
    getter rationale : String = ""
    getter proposed_by : String = "memory_promotion_proposer"
    getter resolved_by : String = ""
    getter resolved_event_id : String = ""
    getter? is_fixture : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      proposal_id : String, artifact_id : String, artifact_version : String = "1",
      direction : PromotionDirection = PromotionDirection::Promote, status : ProposalStatus = ProposalStatus::Proposed,
      reliability_verdict : String = "", helped_outcomes : Int32 = 0,
      evidence_event_ids : Array(String) = [] of String, rule_id : String = "",
      rule_version : Int32 = 0, rationale : String = "", proposed_by : String = "memory_promotion_proposer",
      resolved_by : String = "", resolved_event_id : String = "", is_fixture : Bool = false,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @proposal_id = proposal_id
      @artifact_id = artifact_id
      @artifact_version = artifact_version
      @direction = direction
      @status = status
      @reliability_verdict = reliability_verdict
      @helped_outcomes = helped_outcomes
      @evidence_event_ids = evidence_event_ids
      @rule_id = rule_id
      @rule_version = rule_version
      @rationale = rationale
      @proposed_by = proposed_by
      @resolved_by = resolved_by
      @resolved_event_id = resolved_event_id
      @is_fixture = is_fixture
      @metadata = metadata
    end
  end

  # A graph-visible trigger for memory retrieval.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_retrieval_request", description: "A graph-visible trigger for memory retrieval.")]
  struct MemoryRetrievalRequest
    include JSON::Serializable

    getter query : String
    getter top_k : Int32 = 10
    getter min_score : Float64 = 0.2
    getter category : String?
    getter behavior_name : String?
    getter frame_id : String?
    getter backend_url : String = ":memory:"
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Records a memory retrieval request and its results.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_retrieval", description: "Records a memory retrieval request and results.")]
  struct MemoryRetrieval
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter query : String
    getter request_id : String?
    getter behavior_name : String?
    getter frame_id : String?
    getter results_count : Int32 = 0
    getter item_ids : Array(String) = [] of String
    getter retrieved_at : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      query : String, request_id : String? = nil, behavior_name : String? = nil,
      frame_id : String? = nil, results_count : Int32 = 0,
      item_ids : Array(String) = [] of String, retrieved_at : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @query = query
      @request_id = request_id
      @behavior_name = behavior_name
      @frame_id = frame_id
      @results_count = results_count
      @item_ids = item_ids
      @retrieved_at = retrieved_at
      @metadata = metadata
    end

    define_copy_with(query, request_id, behavior_name, frame_id, results_count, item_ids, retrieved_at, metadata)
  end

  # Scores a MemoryItem's relevance for a specific retrieval.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_ranking", description: "Scores a MemoryItem's relevance for a specific retrieval.")]
  struct MemoryRanking
    include JSON::Serializable

    getter retrieval_id : String
    getter item_id : String
    getter score : Float64
    getter reason : String = ""
    getter rank : Int32 = 1
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      retrieval_id : String, item_id : String, score : Float64, reason : String = "",
      rank : Int32 = 1, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @retrieval_id = retrieval_id
      @item_id = item_id
      @score = score
      @reason = reason
      @rank = rank
      @metadata = metadata
    end
  end

  # Evidence-authoritative result from the default procedure resolver.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_query_resolution", description: "A procedure-selected memory result whose raw evidence remains authoritative.")]
  struct MemoryQueryResolution
    include JSON::Serializable

    getter query : String
    getter subject_ref : String?
    getter selected_tier : ResolutionTier = ResolutionTier::None
    getter procedure_id : String
    getter evidence_ids : Array(String) = [] of String
    getter annotation_ids : Array(String) = [] of String
    getter memory_item_ids : Array(String) = [] of String
    getter context_text : String = ""
    getter confidence : Float64 = 0.0
    getter? authoritative_evidence : Bool = true
    getter coverage : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

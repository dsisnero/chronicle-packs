require "json"

module Chronicle::Packs::SemanticExtraction
  # The shared annotation layer's graph schemas (ADR 0026). Ported from
  # upstream packs/semantic_extraction/object_types.py.

  # One typed, source-anchored annotation under the shared envelope.
  @[Chronicle::Packs::Annotations::ObjectType(name: "semantic_annotation", description: "A typed, source-anchored annotation under the shared provenance envelope.")]
  struct SemanticAnnotation
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter annotation_identity : String
    getter facet : String
    getter body : Hash(String, JSON::Any)
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter selector : Hash(String, JSON::Any)
    getter extractor_id : String
    getter extractor_version : String
    getter config_hash : String
    getter confidence : Float64
    getter attribution : String = "unknown"
    getter author_role : String?
    getter event_time : String?
    getter observation_time : String?
    getter modality : String = "stated"
    getter polarity : String = "positive"
    getter status : String = "active"
    getter invalidation_reason : String?
    getter run_id : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      annotation_identity : String, facet : String, body : Hash(String, JSON::Any),
      evidence_id : String, evidence_identity : String, revision_id : String,
      selector : Hash(String, JSON::Any), extractor_id : String, extractor_version : String,
      config_hash : String, confidence : Float64, run_id : String,
      attribution : String = "unknown", author_role : String? = nil,
      event_time : String? = nil, observation_time : String? = nil,
      modality : String = "stated", polarity : String = "positive",
      status : String = "active", invalidation_reason : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @annotation_identity = annotation_identity
      @facet = facet
      @body = body
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @selector = selector
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @config_hash = config_hash
      @confidence = confidence
      @attribution = attribution
      @author_role = author_role
      @event_time = event_time
      @observation_time = observation_time
      @modality = modality
      @polarity = polarity
      @status = status
      @invalidation_reason = invalidation_reason
      @run_id = run_id
      @metadata = metadata
    end

    define_copy_with(annotation_identity, facet, body, evidence_id, evidence_identity, revision_id, selector, extractor_id, extractor_version, config_hash, confidence, attribution, author_role, event_time, observation_time, modality, polarity, status, invalidation_reason, run_id, metadata)
  end

  # One cache-identified extractor pass over one evidence revision.
  @[Chronicle::Packs::Annotations::ObjectType(name: "extraction_run", description: "One cache-identified annotation-extraction pass over an evidence revision.")]
  struct ExtractionRun
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter run_identity : String
    getter evidence_id : String
    getter evidence_identity : String
    getter revision_id : String
    getter selection_id : String?
    getter extractor_id : String
    getter extractor_version : String
    getter config_hash : String
    getter requested_facets : Array(String)
    getter executed_facets : Array(String) = [] of String
    getter cached_facets : Array(String) = [] of String
    getter annotation_ids : Array(String) = [] of String
    getter status : String = "completed"
    getter error : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      run_identity : String, evidence_id : String, evidence_identity : String,
      revision_id : String, extractor_id : String, extractor_version : String,
      config_hash : String, requested_facets : Array(String), run_id : String = "",
      selection_id : String? = nil, executed_facets : Array(String) = [] of String,
      cached_facets : Array(String) = [] of String, annotation_ids : Array(String) = [] of String,
      status : String = "completed", error : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @run_identity = run_identity
      @evidence_id = evidence_id
      @evidence_identity = evidence_identity
      @revision_id = revision_id
      @selection_id = selection_id
      @extractor_id = extractor_id
      @extractor_version = extractor_version
      @config_hash = config_hash
      @requested_facets = requested_facets
      @executed_facets = executed_facets
      @cached_facets = cached_facets
      @annotation_ids = annotation_ids
      @status = status
      @error = error
      @metadata = metadata
    end

    define_copy_with(run_identity, evidence_id, evidence_identity, revision_id, selection_id, extractor_id, extractor_version, config_hash, requested_facets, executed_facets, cached_facets, annotation_ids, status, error, metadata)
  end

  # What one run did and did not process — a first-class output.
  @[Chronicle::Packs::Annotations::ObjectType(name: "extraction_coverage", description: "What an extraction run did and did not process.")]
  struct ExtractionCoverage
    include JSON::Serializable

    getter coverage_identity : String
    getter run_id : String
    getter evidence_id : String
    getter revision_id : String
    getter processed_facets : Array(String) = [] of String
    getter skipped_facets : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter content_chars_total : Int32
    getter content_chars_processed : Int32
    getter? truncated : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      coverage_identity : String, run_id : String, evidence_id : String, revision_id : String,
      content_chars_total : Int32, content_chars_processed : Int32,
      processed_facets : Array(String) = [] of String,
      skipped_facets : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      truncated : Bool = false, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @coverage_identity = coverage_identity
      @run_id = run_id
      @evidence_id = evidence_id
      @revision_id = revision_id
      @processed_facets = processed_facets
      @skipped_facets = skipped_facets
      @content_chars_total = content_chars_total
      @content_chars_processed = content_chars_processed
      @truncated = truncated
      @metadata = metadata
    end
  end

  record SelectionExtraction,
    start : Int32,
    end : Int32,
    exact_hash : String do
    include JSON::Serializable
  end

  # A generic exact-span request from a domain projector.
  @[Chronicle::Packs::Annotations::ObjectType(name: "selection_extraction_request", description: "A generic exact-evidence-span extraction request from a domain projector.")]
  struct SelectionExtractionRequest
    include JSON::Serializable

    getter request_identity : String
    getter evidence_id : String
    getter revision_id : String
    getter selection_id : String
    getter selections : Array(SelectionExtraction)
    getter requested_facets : Array(String)
    getter status : String = "proposed"
    getter run_ids : Array(String) = [] of String
    getter annotation_ids : Array(String) = [] of String
    getter error : String?
    getter refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Versioned, owner-editable facet policy per source category (D042).
  @[Chronicle::Packs::Annotations::ObjectType(name: "extraction_profile", description: "Versioned owner-editable facet policy per source category.")]
  struct ExtractionProfile
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter profile_identity : String
    getter version : Int32
    getter status : String = "active"
    getter default_facets : Array(String)
    getter facets_by_source_category : Hash(String, Array(String)) = {} of String => Array(String)
    getter extractor_by_facet : Hash(String, String) = {} of String => String
    getter created_by : String
    getter rationale : String = ""
    getter supersedes_profile_id : String?

    def initialize(
      profile_identity : String, version : Int32, default_facets : Array(String), created_by : String,
      status : String = "active", facets_by_source_category : Hash(String, Array(String)) = {} of String => Array(String),
      extractor_by_facet : Hash(String, String) = {} of String => String, rationale : String = "",
      supersedes_profile_id : String? = nil,
    )
      @profile_identity = profile_identity
      @version = version
      @status = status
      @default_facets = default_facets
      @facets_by_source_category = facets_by_source_category
      @extractor_by_facet = extractor_by_facet
      @created_by = created_by
      @rationale = rationale
      @supersedes_profile_id = supersedes_profile_id
    end

    define_copy_with(profile_identity, version, status, default_facets, facets_by_source_category, extractor_by_facet, created_by, rationale, supersedes_profile_id)
  end

  # Eligibility of one annotation-extractor version.
  @[Chronicle::Packs::Annotations::ObjectType(name: "annotation_extractor_state", description: "Eligibility state of an annotation-extractor version.")]
  struct AnnotationExtractorState
    include JSON::Serializable

    getter state_identity : String
    getter extractor_id : String
    getter extractor_version : String
    getter status : String = "enabled"
    getter reason : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # One recorded extractor trial — the ADR 0014 promotion-evidence shape.
  @[Chronicle::Packs::Annotations::ObjectType(name: "extractor_promotion_evidence", description: "A recorded extractor trial: candidate vs baseline on recorded content.")]
  struct ExtractorPromotionEvidence
    include JSON::Serializable

    getter evidence_identity : String
    getter candidate_extractor_id : String
    getter candidate_extractor_version : String
    getter baseline_extractor_id : String
    getter baseline_extractor_version : String
    getter evidence_ids : Array(String)
    getter facets : Array(String)
    getter comparison : Hash(String, Hash(String, Int64)) = {} of String => Hash(String, Int64)
    getter verdict : String
    getter rationale : String = ""
    getter created_by : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A calibrated applicability guard for one deterministic procedure.
  @[Chronicle::Packs::Annotations::ObjectType(name: "procedure_guard", description: "A calibrated applicability guard for one deterministic procedure.")]
  struct ProcedureGuard
    include JSON::Serializable

    getter guard_identity : String
    getter guard_kind : String = "shape_and_cue"
    getter source_category : String
    getter facet : String
    getter shape_fingerprints : Array(String)
    getter cue_pattern_id : String
    getter max_content_chars : Int32
    getter false_admissions : Int32 = 0
    getter abstentions : Int32 = 0
    getter calibration_examples : Int32 = 0
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A declared deterministic extraction procedure and its reference contract.
  @[Chronicle::Packs::Annotations::ObjectType(name: "procedure_candidate", description: "A declared deterministic extraction procedure and its reference/fallback contract.")]
  struct ProcedureCandidate
    include JSON::Serializable

    getter candidate_identity : String
    getter domain : String = "semantic_extraction"
    getter procedure_kind : String = "deterministic_parser"
    getter candidate_ref : String
    getter reference_ref : String
    getter facet : String
    getter semantic_objective : String
    getter equivalence_rule : String = "facet_exact_selector"
    getter input_schema : Hash(String, JSON::Any)
    getter output_schema : Hash(String, JSON::Any)
    getter allowed_effects : Array(String) = [] of String
    getter required_capabilities : Array(String) = [] of String
    getter action_class : String = "R0"
    getter resource_bounds : Hash(String, JSON::Any)
    getter witness_evidence_ids : Array(String)
    getter held_out_evidence_ids : Array(String)
    getter counterexample_evidence_ids : Array(String)
    getter reference_annotation_ids : Array(String)
    getter correction_evaluation_ids : Array(String)
    getter guard_id : String
    getter fallback_ref : String
    getter status : String = "candidate"
    getter status_reason : String = ""
    getter created_by : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Forked witnessed/held-out/counterexample evaluation of a procedure candidate.
  @[Chronicle::Packs::Annotations::ObjectType(name: "procedure_evaluation", description: "Forked witnessed/held-out/counterexample evaluation of a procedure candidate.")]
  struct ProcedureEvaluation
    include JSON::Serializable

    getter evaluation_identity : String
    getter candidate_id : String
    getter fork_run_id : String
    getter forked_at_event_id : String
    getter witness_count : Int32 = 0
    getter held_out_count : Int32 = 0
    getter counterexample_count : Int32 = 0
    getter witness_parity_milli : Int32 = 0
    getter held_out_parity_milli : Int32 = 0
    getter false_admissions : Int32 = 0
    getter false_rejections : Int32 = 0
    getter selector_mismatches : Int32 = 0
    getter guard_abstentions : Int32 = 0
    getter candidate_calls : Int32 = 0
    getter reference_calls : Int32 = 0
    getter verdict : String
    getter failures : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter evidence_refs : Array(String) = [] of String
    getter correction_evaluation_ids : Array(String) = [] of String
    getter promote_marker_event_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A guard abstention, drift, failure, or mismatch that fell back.
  @[Chronicle::Packs::Annotations::ObjectType(name: "procedure_deoptimization", description: "A guard abstention, drift, failure, or mismatch that fell back to the reference path.")]
  struct ProcedureDeoptimization
    include JSON::Serializable

    getter deoptimization_identity : String
    getter candidate_id : String
    getter evidence_id : String
    getter reason : String
    getter guard_id : String
    getter fallback_ref : String
    getter fallback_status : String = "requested"
    getter fallback_run_ids : Array(String) = [] of String
    getter input_fingerprint : String
    getter evidence_refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

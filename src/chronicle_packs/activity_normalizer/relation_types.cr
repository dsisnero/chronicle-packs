module Chronicle::Packs::ActivityNormalizer
  # Activity Normalizer relation types. Ported from upstream
  # packs/activity_normalizer/object_types.py.

  # Normalized content belongs to one acquired item.
  @[Chronicle::Packs::Annotations::RelationType(name: "content_for", source_types: ["acquired_content"], target_types: ["acquired_item"], description: "Normalized content belongs to one acquired item.")]
  struct ContentFor
  end

  # An acquired-content handoff normalizes into evidence.
  @[Chronicle::Packs::Annotations::RelationType(name: "normalizes_to", source_types: ["acquired_content"], target_types: ["activity_evidence"], description: "An acquired-content handoff normalizes into evidence.")]
  struct NormalizesTo
  end

  # Evidence preserves its exact acquisition provenance.
  @[Chronicle::Packs::Annotations::RelationType(name: "acquired_from", source_types: ["activity_evidence"], target_types: ["acquired_item"], description: "Evidence preserves its exact acquisition provenance.")]
  struct AcquiredFrom
  end

  # A new evidence revision supersedes an older revision.
  @[Chronicle::Packs::Annotations::RelationType(name: "supersedes", source_types: ["activity_evidence"], target_types: ["activity_evidence"], description: "A new evidence revision supersedes an older revision.")]
  struct Supersedes
  end

  # An extraction record evaluates one evidence revision.
  @[Chronicle::Packs::Annotations::RelationType(name: "extraction_for", source_types: ["extraction_record"], target_types: ["activity_evidence"], description: "An extraction record evaluates one evidence revision.")]
  struct ExtractionFor
  end

  # A versioned extraction produced a candidate.
  @[Chronicle::Packs::Annotations::RelationType(name: "produced_candidate", source_types: ["extraction_record"], target_types: ["memory_candidate", "preference_candidate", "task_candidate", "profile_candidate", "skill_candidate", "eval_candidate"], description: "A versioned extraction produced a candidate.")]
  struct ProducedCandidate
  end

  # A candidate traces directly to its evidence revision.
  @[Chronicle::Packs::Annotations::RelationType(name: "extracted_from", source_types: ["memory_candidate", "preference_candidate", "task_candidate", "profile_candidate", "skill_candidate", "eval_candidate"], target_types: ["activity_evidence"], description: "A candidate traces directly to its evidence revision.")]
  struct ExtractedFrom
  end

  # A failure identifies the pipeline object it affected.
  @[Chronicle::Packs::Annotations::RelationType(name: "failure_for", source_types: ["ingestion_failure"], target_types: ["acquired_item", "acquired_content", "activity_evidence"], description: "A failure identifies the pipeline object it affected.")]
  struct FailureFor
  end
end

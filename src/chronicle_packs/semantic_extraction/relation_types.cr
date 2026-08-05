module Chronicle::Packs::SemanticExtraction
  # Semantic Extraction relation types. Ported from upstream
  # packs/semantic_extraction/object_types.py.

  @[Chronicle::Packs::Annotations::RelationType(name: "annotation_for", source_types: ["semantic_annotation"], target_types: ["activity_evidence"], description: "An annotation anchors to one evidence revision.")]
  struct AnnotationFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "produced_annotation", source_types: ["extraction_run"], target_types: ["semantic_annotation"], description: "A cache-identified run produced an annotation.")]
  struct ProducedAnnotation
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "run_for", source_types: ["extraction_run"], target_types: ["activity_evidence"], description: "An extraction run evaluated one evidence revision.")]
  struct RunFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "coverage_for", source_types: ["extraction_coverage"], target_types: ["extraction_run"], description: "A coverage record describes one extraction run.")]
  struct CoverageFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "projected_from_annotation", source_types: ["profile_candidate", "memory_candidate", "preference_candidate", "task_candidate", "skill_candidate", "eval_candidate"], target_types: ["semantic_annotation"], description: "A domain candidate was minted by a projector from an annotation.")]
  struct ProjectedFromAnnotation
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "procedure_has_guard", source_types: ["procedure_candidate"], target_types: ["procedure_guard"], description: "A procedure candidate's versioned applicability guard.")]
  struct ProcedureHasGuard
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "procedure_evaluated_by", source_types: ["procedure_candidate"], target_types: ["procedure_evaluation"], description: "A procedure candidate's forked evaluation.")]
  struct ProcedureEvaluatedBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "procedure_deoptimized_by", source_types: ["procedure_candidate"], target_types: ["procedure_deoptimization"], description: "A promoted procedure fell back to its dynamic reference.")]
  struct ProcedureDeoptimizedBy
  end
end

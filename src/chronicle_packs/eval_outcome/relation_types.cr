module Chronicle::Packs::EvalOutcome
  # Eval Outcome relation types. Ported from upstream
  # packs/eval_outcome/object_types.py.

  # A terminal or maintenance outcome traces to its Core evaluation.
  @[Chronicle::Packs::Annotations::RelationType(name: "records_evaluation", source_types: ["outcome_record"], target_types: ["evaluation"])]
  struct RecordsEvaluation
  end

  # An outcome is evidence in one artifact reliability projection.
  @[Chronicle::Packs::Annotations::RelationType(name: "updates_reliability", source_types: ["outcome_record"], target_types: ["artifact_reliability"])]
  struct UpdatesReliability
  end
end

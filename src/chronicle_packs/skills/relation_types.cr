module Chronicle::Packs::Skills
  # Skills relation types. Ported from upstream packs/skills/object_types.py.

  # A usage invokes one exact skill version.
  @[Chronicle::Packs::Annotations::RelationType(name: "usage_of", source_types: ["skill_usage"], target_types: ["skill"])]
  struct UsageOf
  end

  # Promotion proof supports one exact skill version.
  @[Chronicle::Packs::Annotations::RelationType(name: "promotion_for", source_types: ["skill_promotion_evidence"], target_types: ["skill"])]
  struct PromotionFor
  end

  # A link identifies the usage that was evaluated.
  @[Chronicle::Packs::Annotations::RelationType(name: "evaluation_of_usage", source_types: ["skill_evaluation_link"], target_types: ["skill_usage"])]
  struct EvaluationOfUsage
  end

  # A skill evaluation link names its Core evaluation.
  @[Chronicle::Packs::Annotations::RelationType(name: "links_evaluation", source_types: ["skill_evaluation_link"], target_types: ["evaluation"])]
  struct LinksEvaluation
  end
end

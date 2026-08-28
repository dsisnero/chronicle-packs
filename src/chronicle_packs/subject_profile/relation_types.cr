module Chronicle::Packs::SubjectProfile
  # Subject Profile Pack relation types. Ported from upstream
  # packs/subject_profile/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "verdict_for_profile_candidate", source_types: ["subject_fact_verdict"], target_types: ["profile_candidate"], description: "A verdict reviews a profile candidate.")]
  struct VerdictForProfileCandidate
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "promoted_from_profile_candidate", source_types: ["subject_fact"], target_types: ["profile_candidate"], description: "A subject fact was explicitly promoted from a candidate.")]
  struct PromotedFromProfileCandidate
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "subject_fact_grounded_in", source_types: ["subject_fact"], target_types: ["activity_evidence"], description: "A subject fact resolves to its evidence revision.")]
  struct SubjectFactGroundedIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "subject_fact_supersedes", source_types: ["subject_fact"], target_types: ["subject_fact"], description: "A corrected or forgotten fact supersedes a prior fact.")]
  struct SubjectFactSupersedes
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "contradiction_involves", source_types: ["subject_contradiction"], target_types: ["subject_fact"], description: "A contradiction references a subject fact.")]
  struct ContradictionInvolves
  end
end

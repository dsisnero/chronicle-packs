module Chronicle::Packs::Entity
  # Entity relation types. Ported from upstream
  # packs/entity/object_types.py RELATION_TYPES.

  # A source or evidence revision contains an entity mention.
  @[Chronicle::Packs::Annotations::RelationType(name: "mentions", source_types: ["source", "activity_evidence"], target_types: ["entity_mention"])]
  struct Mentions
  end

  # An entity mention refers to a resolved entity.
  @[Chronicle::Packs::Annotations::RelationType(name: "refers_to", source_types: ["entity_mention"], target_types: ["entity"])]
  struct RefersTo
  end

  # A merge candidate involves an entity (both sides).
  @[Chronicle::Packs::Annotations::RelationType(name: "merge_candidate_for", source_types: ["merge_candidate"], target_types: ["entity"])]
  struct MergeCandidateFor
  end

  # A merge decision resolves a merge candidate.
  @[Chronicle::Packs::Annotations::RelationType(name: "decided_by", source_types: ["merge_decision"], target_types: ["merge_candidate"])]
  struct DecidedBy
  end

  # An entity was merged into another entity after a dedup decision.
  @[Chronicle::Packs::Annotations::RelationType(name: "merged_into", source_types: ["entity"], target_types: ["entity"])]
  struct MergedInto
  end
end

module Chronicle::Packs::MemoryGateway
  # Memory Gateway relation types. Ported from upstream
  # packs/memory_gateway/object_types.py.

  @[Chronicle::Packs::Annotations::RelationType(name: "promotion_proposal_for", source_types: ["memory_promotion_proposal"], target_types: ["memory_item"], description: "A promote/demote proposal targets one memory item version.")]
  struct PromotionProposalFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "accepted_as", source_types: ["memory_candidate"], target_types: ["memory_item"], description: "An accepted memory_candidate is promoted to a MemoryItem.")]
  struct AcceptedAs
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "fulfilled_by", source_types: ["memory_retrieval_request"], target_types: ["memory_retrieval"], description: "A retrieval request is fulfilled by a retrieval result.")]
  struct FulfilledBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "ranked_in", source_types: ["memory_item"], target_types: ["memory_retrieval"], description: "A MemoryItem appears in a retrieval result set.")]
  struct RankedIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "scored_by", source_types: ["memory_ranking"], target_types: ["memory_retrieval"], description: "A MemoryRanking scores a MemoryItem in a retrieval.")]
  struct ScoredBy
  end
end

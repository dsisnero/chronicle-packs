module Chronicle::Packs::Evolution
  # Evolution Pack relation types. Ported from upstream
  # packs/evolution/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "proposes_fix_for", source_types: ["mod_proposal"], target_types: ["capability_gap"], description: "A proposal addresses a gap.")]
  struct ProposesFixFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "gated_by", source_types: ["mod_proposal"], target_types: ["gate_result"], description: "A proposal's gate verdicts.")]
  struct GatedBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "trialed_in", source_types: ["mod_proposal"], target_types: ["mod_trial"], description: "A proposal's fork trials.")]
  struct TrialedIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "promoted_as", source_types: ["mod_proposal"], target_types: ["mod_promotion"], description: "A proposal's adoption record.")]
  struct PromotedAs
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "rolled_back_by", source_types: ["mod_promotion"], target_types: ["mod_rollback"], description: "A promotion's rollback record.")]
  struct RolledBackBy
  end
end

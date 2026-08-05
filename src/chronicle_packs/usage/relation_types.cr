module Chronicle::Packs::Usage
  # Usage relation types. Ported from upstream packs/usage/object_types.py.

  # A normalizer evidence identity was observed on a connection surface.
  @[Chronicle::Packs::Annotations::RelationType(name: "evidence_on_surface", source_types: ["usage_evidence"], target_types: ["connection_surface"], description: "A normalizer evidence identity was observed on a connection surface.")]
  struct EvidenceOnSurface
  end

  # A historical settlement pass belongs to a connection surface.
  @[Chronicle::Packs::Annotations::RelationType(name: "settlement_for", source_types: ["settlement_record"], target_types: ["connection_surface"], description: "A historical settlement pass belongs to a connection surface.")]
  struct SettlementFor
  end

  # An interaction observation belongs to a connection surface.
  @[Chronicle::Packs::Annotations::RelationType(name: "usage_on_surface", source_types: ["usage_record"], target_types: ["connection_surface"], description: "An interaction observation belongs to a connection surface.")]
  struct UsageOnSurface
  end
end

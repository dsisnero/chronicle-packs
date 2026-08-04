module Chronicle::Packs::IdentityAuth
  # Identity/Auth relation types. Ported from upstream
  # packs/identity_auth/object_types.py RELATION_TYPES.

  # A source or comm_message resolves to a principal.
  @[Chronicle::Packs::Annotations::RelationType(name: "resolves_to", source_types: ["source", "comm_message"], target_types: ["principal"])]
  struct ResolvesTo
  end

  # A principal is authenticated by an auth context.
  @[Chronicle::Packs::Annotations::RelationType(name: "authenticated_by", source_types: ["principal"], target_types: ["auth_context"])]
  struct AuthenticatedBy
  end

  # A delegation is granted by a principal.
  @[Chronicle::Packs::Annotations::RelationType(name: "granted_by", source_types: ["delegation"], target_types: ["principal"])]
  struct GrantedBy
  end

  # A delegation is granted to a principal.
  @[Chronicle::Packs::Annotations::RelationType(name: "granted_to", source_types: ["delegation"], target_types: ["principal"])]
  struct GrantedTo
  end

  # A principal is linked to an Entity pack entity.
  @[Chronicle::Packs::Annotations::RelationType(name: "linked_to_entity", source_types: ["principal"], target_types: ["entity"])]
  struct LinkedToEntity
  end
end

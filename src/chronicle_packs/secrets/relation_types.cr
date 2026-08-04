module Chronicle::Packs::Secrets
  # Secrets relation types. Ported from upstream
  # packs/secrets/object_types.py RELATION_TYPES.

  # A secret usage event is associated with a capability call.
  @[Chronicle::Packs::Annotations::RelationType(name: "credential_used_in", source_types: ["secret_usage_event"], target_types: ["capability_call"])]
  struct CredentialUsedIn
  end

  # A credential reference is governed by a secret scope.
  @[Chronicle::Packs::Annotations::RelationType(name: "governed_by", source_types: ["credential_ref"], target_types: ["secret_scope"])]
  struct GovernedBy
  end
end

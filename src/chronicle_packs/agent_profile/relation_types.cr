module Chronicle::Packs::AgentProfile
  # Agent Profile relation types. Ported from upstream
  # packs/agent_profile/object_types.py RELATION_TYPES.

  # A profile owns a goal.
  @[Chronicle::Packs::Annotations::RelationType(name: "owns_goal", source_types: ["agent_profile"], target_types: ["goal"])]
  struct OwnsGoal
  end

  # A profile owns a standing instruction.
  @[Chronicle::Packs::Annotations::RelationType(name: "owns_instruction", source_types: ["agent_profile"], target_types: ["standing_instruction"])]
  struct OwnsInstruction
  end

  # A profile owns an owner preference.
  @[Chronicle::Packs::Annotations::RelationType(name: "owns_preference", source_types: ["agent_profile"], target_types: ["owner_preference"])]
  struct OwnsPreference
  end

  # A context request is fulfilled by a context view.
  @[Chronicle::Packs::Annotations::RelationType(name: "fulfilled_by_profile", source_types: ["profile_context_request"], target_types: ["profile_context_view"])]
  struct FulfilledByProfile
  end

  # An auth_context or frame auto-triggers a profile context request.
  @[Chronicle::Packs::Annotations::RelationType(name: "triggers_context_for", source_types: ["auth_context", "frame"], target_types: ["profile_context_request"])]
  struct TriggersContextFor
  end
end

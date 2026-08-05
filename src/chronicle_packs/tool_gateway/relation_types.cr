module Chronicle::Packs::ToolGateway
  # Tool Gateway relation types. Ported from upstream
  # packs/tool_gateway/object_types.py.

  @[Chronicle::Packs::Annotations::RelationType(name: "integration_supersedes", source_types: ["integration_profile"], target_types: ["integration_profile"], description: "A refreshed integration profile supersedes its prior version.")]
  struct IntegrationSupersedes
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "profile_explored_by", source_types: ["integration_profile"], target_types: ["integration_exploration"], description: "An integration profile was supported by a recorded exploration receipt.")]
  struct ProfileExploredBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "calls", source_types: ["capability_call"], target_types: ["capability_provider"], description: "A capability call invokes a capability provider.")]
  struct Calls
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "approved_by", source_types: ["capability_call"], target_types: ["capability_approval"], description: "A capability call is approved by a capability_approval record.")]
  struct ApprovedBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "denied_by", source_types: ["capability_call"], target_types: ["capability_denial"], description: "A capability call was denied by a capability_denial record.")]
  struct DeniedBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "produces_result", source_types: ["capability_call"], target_types: ["capability_result"], description: "An executed capability call produces a result.")]
  struct ProducesResult
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "sourced_as", source_types: ["capability_result"], target_types: ["source"], description: "A capability result is sourced as a Core source object.")]
  struct SourcedAs
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "flags", source_types: ["injection_flag"], target_types: ["capability_result"], description: "An injection_flag marks a capability_result as suspect.")]
  struct Flags
  end
end

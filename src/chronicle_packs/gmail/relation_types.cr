module Chronicle::Packs::Gmail
  # Gmail relation types. Ported from upstream packs/gmail/object_types.py
  # (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "gmail_sync_call", source_types: ["gmail_sync_run"], target_types: ["capability_call"], description: "A bounded Gmail sync run proposed a recorded provider call.")]
  struct GmailSyncCall
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "gmail_draft_call", source_types: ["gmail_draft_candidate"], target_types: ["capability_call"], description: "A local draft proposed a Gmail write or send capability.")]
  struct GmailDraftCall
  end
end

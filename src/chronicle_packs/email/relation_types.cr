module Chronicle::Packs::Email
  # Email relation types. Ported from upstream
  # packs/email/manifest.toml (relation_types list).

  @[Chronicle::Packs::Annotations::RelationType(name: "email_thread_contains", source_types: ["email_thread"], target_types: ["email_message"], description: "An EmailThread contains an EmailMessage.")]
  struct EmailThreadContains
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "draft_responds_to", source_types: ["email_draft"], target_types: ["email_message"], description: "An EmailDraft is a response to an EmailMessage.")]
  struct DraftRespondsTo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "draft_from_candidate", source_types: ["email_draft"], target_types: ["comm_response_candidate"], description: "An EmailDraft was produced from a CommResponseCandidate.")]
  struct DraftFromCandidate
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "email_linked_to_comm_thread", source_types: ["email_thread"], target_types: ["comm_thread"], description: "An EmailThread corresponds to a CommThread.")]
  struct EmailLinkedToCommThread
  end
end

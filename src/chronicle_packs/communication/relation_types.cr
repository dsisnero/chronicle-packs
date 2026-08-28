module Chronicle::Packs::Communication
  # Communication relation types. Ported from upstream
  # packs/communication/manifest.toml (relation_types list). Processor
  # source/target directions match how the ported behaviors write relations.

  @[Chronicle::Packs::Annotations::RelationType(name: "thread_contains", source_types: ["comm_thread"], target_types: ["comm_message"], description: "A thread contains a comm message.")]
  struct ThreadContains
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "intent_of", source_types: ["comm_intent"], target_types: ["comm_message"], description: "An intent was detected for a comm message.")]
  struct IntentOf
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "response_to", source_types: ["comm_message"], target_types: ["comm_message"], description: "A comm message responds to another comm message.")]
  struct ResponseTo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "participates_in", source_types: ["comm_participant"], target_types: ["comm_thread"], description: "A participant participates in a thread.")]
  struct ParticipatesIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "derived_from_source_comm", source_types: ["comm_message"], target_types: ["comm_message"], description: "A comm message derives from a source comm message.")]
  struct DerivedFromSourceComm
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "dispatched_to", source_types: ["comm_response_candidate"], target_types: ["comm_thread"], description: "A response candidate was dispatched to a thread.")]
  struct DispatchedTo
  end

  # Source open (empty = any): the delivering object is a capability_call,
  # owned by the OPTIONAL Tool Gateway Pack. Channel adapters (telegram,
  # whatsapp, ...) create instances when they hand an approved candidate to
  # the gateway for external delivery.
  @[Chronicle::Packs::Annotations::RelationType(name: "delivers", source_types: [] of String, target_types: ["comm_response_candidate"], description: "A Tool Gateway capability_call delivers an approved response candidate to its external channel.")]
  struct Delivers
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "fulfills_intent", source_types: ["capability_call"], target_types: ["comm_intent"], description: "A capability call fulfills an intent.")]
  struct FulfillsIntent
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "conversation_contains", source_types: ["conversation_thread"], target_types: ["conversation_message"], description: "A conversation thread contains a conversation message.")]
  struct ConversationContains
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "conversation_has_participant", source_types: ["conversation_thread"], target_types: ["conversation_participant"], description: "A conversation thread has a participant.")]
  struct ConversationHasParticipant
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "conversation_message_from_evidence", source_types: ["conversation_message"], target_types: ["activity_evidence"], description: "A conversation message is materialized from an evidence revision.")]
  struct ConversationMessageFromEvidence
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "conversation_participant_mention", source_types: ["conversation_participant"], target_types: ["entity_mention"], description: "A participant is mentioned in a conversation message.")]
  struct ConversationParticipantMention
  end
end

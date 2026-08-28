require "json"

module Chronicle::Packs::Chat
  # Chat Adapter Pack relation types. Ported from upstream
  # packs/chat/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "session_contains_turn", source_types: ["chat_session"], target_types: ["chat_turn"], description: "A ChatSession contains a ChatTurn.")]
  struct SessionContainsTurn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "turn_from_input", source_types: ["chat_turn"], target_types: ["chat_input"], description: "A ChatTurn was created from a ChatInput.")]
  struct TurnFromInput
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "session_has_thread", source_types: ["chat_session"], target_types: ["comm_thread"], description: "A ChatSession corresponds to a CommThread.")]
  struct SessionHasThread
  end

  # A context object (ChatContext conversation memory, MemoryContext
  # long-term memory, or ProfileContextView identity) provides context for
  # an inbound CommMessage. This edge lets chat_llm_responder's depth-1 view
  # capture the context without widening its scope. Naming an Agent Profile
  # type here is a string-only reference — it is validated lazily at
  # add_relation time, so the Chat Pack still loads standalone (without
  # agent_profile), in which case no profile_context_view is ever created.
  @[Chronicle::Packs::Annotations::RelationType(name: "provides_context_for", source_types: ["chat_context", "profile_context_view", "memory_context"], target_types: ["comm_message"], description: "A context object (ChatContext conversation memory, MemoryContext long-term memory, or ProfileContextView identity) provides context for an inbound CommMessage.")]
  struct ProvidesContextFor
  end
end

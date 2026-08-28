module Chronicle::Packs::Telegram
  # Telegram Adapter Pack relation types. Ported from upstream
  # packs/telegram/object_types.py (RELATION_TYPES). The `delivers` relation
  # the messenger dispatchers use is declared by the Communication Pack —
  # adapters only create instances of it.
  @[Chronicle::Packs::Annotations::RelationType(name: "ingested_as", source_types: ["telegram_update"], target_types: ["chat_input"], description: "A Telegram update was ingested as a chat_input.")]
  struct IngestedAs
  end
end

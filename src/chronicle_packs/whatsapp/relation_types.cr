module Chronicle::Packs::WhatsApp
  # WhatsApp Adapter Pack relation types. Ported from upstream
  # packs/whatsapp/object_types.py (RELATION_TYPES). The `delivers` relation
  # the messenger dispatchers use is declared by the Communication Pack —
  # adapters only create instances of it.
  @[Chronicle::Packs::Annotations::RelationType(name: "wa_ingested_as", source_types: ["whatsapp_message"], target_types: ["chat_input"], description: "A WhatsApp message was ingested as a chat_input.")]
  struct WaIngestedAs
  end
end

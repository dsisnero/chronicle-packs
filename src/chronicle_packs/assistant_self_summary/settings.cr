require "json"

module Chronicle::Packs::AssistantSelfSummary
  # Bounds for assistant self-summary ingestion. Ported from upstream
  # packs/importers/assistant_self_summary/settings.py.
  struct AssistantSelfSummarySettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter max_summary_chars : Int32 = 64_000
    getter max_normalized_chars : Int32 = 32_000

    def initialize(
      @max_summary_chars : Int32 = 64_000,
      @max_normalized_chars : Int32 = 32_000,
    )
    end
  end
end

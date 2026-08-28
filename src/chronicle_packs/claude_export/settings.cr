require "json"

module Chronicle::Packs::ClaudeExport
  # Bounds and replay defaults for official Claude export snapshots. Ported
  # from upstream packs/importers/claude_export/settings.py.
  struct ClaudeExportSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter artifact_store_dir : String = ".activegraph/replay-artifacts"
    getter replay_mode : String = "artifact"
    getter max_archive_bytes : Int64 = 1_000_000_000
    getter max_conversations_json_bytes : Int64 = 256_000_000
    getter max_compression_ratio : Int32 = 200
    getter max_conversations : Int32 = 10_000
    getter max_messages_per_conversation : Int32 = 10_000
    getter max_messages : Int32 = 250_000
    getter max_normalized_chars : Int32 = 32_000

    def initialize(
      @artifact_store_dir : String = ".activegraph/replay-artifacts",
      @replay_mode : String = "artifact",
      @max_archive_bytes : Int64 = 1_000_000_000,
      @max_conversations_json_bytes : Int64 = 256_000_000,
      @max_compression_ratio : Int32 = 200,
      @max_conversations : Int32 = 10_000,
      @max_messages_per_conversation : Int32 = 10_000,
      @max_messages : Int32 = 250_000,
      @max_normalized_chars : Int32 = 32_000,
    )
    end
  end
end

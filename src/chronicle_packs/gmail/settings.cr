require "json"

module Chronicle::Packs::Gmail
  # Gmail connector policy. Bounds are versioned settings, not architecture.
  # Ported from upstream packs/gmail/settings.py (GmailSettings).
  struct GmailSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter toolkit_version : String = "latest"
    getter artifact_store_dir : String = ".activegraph/replay-artifacts"
    getter default_query : String = "newer_than:30d"
    getter default_page_size : Int32 = 25
    getter default_max_messages : Int32 = 250
    getter default_max_pages : Int32 = 10
    getter live_poll_max_messages : Int32 = 100
    getter max_normalized_chars : Int32 = 32_000
    getter max_replay_payload_bytes : Int32 = 5_000_000

    def initialize(
      @toolkit_version : String = "latest",
      @artifact_store_dir : String = ".activegraph/replay-artifacts",
      @default_query : String = "newer_than:30d",
      @default_page_size : Int32 = 25,
      @default_max_messages : Int32 = 250,
      @default_max_pages : Int32 = 10,
      @live_poll_max_messages : Int32 = 100,
      @max_normalized_chars : Int32 = 32_000,
      @max_replay_payload_bytes : Int32 = 5_000_000,
    )
    end
  end
end

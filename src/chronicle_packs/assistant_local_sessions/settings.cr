require "json"

module Chronicle::Packs::AssistantLocalSessions
  # Bounds, window defaults, and default roots for local agent-session logs.
  # Ported from upstream packs/importers/assistant_local_sessions/settings.py.
  #
  # Default provider roots live here — never in the importer. Callers expand
  # `~` and pass an absolute root_path to the tool.
  struct AssistantLocalSessionsSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter claude_code_root_path : String = "~/.claude/projects"
    getter codex_root_path : String = "~/.codex/sessions"
    getter artifact_store_dir : String = ".activegraph/replay-artifacts"
    getter replay_mode : String = "artifact"
    getter max_sessions : Int32 = 20
    getter max_file_bytes : Int64 = 50_000_000
    getter max_lines_per_file : Int32 = 100_000
    getter max_messages : Int32 = 25_000
    getter max_normalized_chars : Int32 = 16_000

    def initialize(
      @claude_code_root_path : String = "~/.claude/projects",
      @codex_root_path : String = "~/.codex/sessions",
      @artifact_store_dir : String = ".activegraph/replay-artifacts",
      @replay_mode : String = "artifact",
      @max_sessions : Int32 = 20,
      @max_file_bytes : Int64 = 50_000_000,
      @max_lines_per_file : Int32 = 100_000,
      @max_messages : Int32 = 25_000,
      @max_normalized_chars : Int32 = 16_000,
    )
    end
  end
end

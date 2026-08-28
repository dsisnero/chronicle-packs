require "json"

module Chronicle::Packs::LocalFiles
  # Settings for the bounded Local Files snapshot importer. Ported from
  # upstream packs/importers/local_files/settings.py (LocalFilesSettings).
  struct LocalFilesSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter artifact_store_dir : String = ".activegraph/replay-artifacts"
    getter replay_mode : String = "artifact"
    getter max_files : Int32 = 1000
    getter max_file_bytes : Int32 = 2_000_000
    getter max_normalized_chars : Int32 = 8192
    getter extensions : Array(String) = [".txt", ".md", ".markdown", ".json"]

    def initialize(
      @artifact_store_dir : String = ".activegraph/replay-artifacts",
      @replay_mode : String = "artifact",
      @max_files : Int32 = 1000,
      @max_file_bytes : Int32 = 2_000_000,
      @max_normalized_chars : Int32 = 8192,
      @extensions : Array(String) = [".txt", ".md", ".markdown", ".json"],
    )
    end
  end
end

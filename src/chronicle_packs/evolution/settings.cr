require "json"

module Chronicle::Packs::Evolution
  # Default import allow-list (design §3 gate 4). Nested so the DSL pack
  # macro does not treat it as an object type constant.
  module DefaultImportAllow
    LIST = ["__future__", "typing", "datetime", "json", "re", "math", "dataclasses", "pydantic", "activegraph.packs"]
  end

  # Fixtures are test harness, exempted per the design (gate 4 exemption).
  module DefaultFixtureExtraAllow
    LIST = ["sys", "pathlib", "activegraph"]
  end

  # Reserved namespaces an authored pack may never register into (gate 6).
  module DefaultReservedNamespaces
    LIST = ["tool_gateway", "evolution", "mcp"]
  end

  # Reserved repo paths an authored pack may never target (charter gate).
  module DefaultReservedPaths
    LIST = [AuthorFrame::AUTHOR_CHARTER_FILENAME]
  end

  module DefaultCrystalAllowedFiles
    LIST = [
      "manifest.toml", "pack.cr", "object_types.cr", "relation_types.cr",
      "behaviors.cr", "tools.cr", "settings.cr", "capabilities.cr",
    ]
  end

  module DefaultCrystalRequireAllow
    LIST = ["json", "time", "digest", "uuid", "uri", "chronicle-packs"]
  end

  # Configuration for Evolution Pack v0.1.
  #
  # Shipped default is OFF: self-modification is opt-in, never ambient.
  struct EvolutionSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = false
    getter max_total_source_bytes : Int32 = 24_000
    getter max_file_bytes : Int32 = 12_000
    getter gap_failure_threshold : Int32 = 3
    getter trial_max_new_events : Int32 = 2_000
    getter trial_fixture_timeout_seconds : Float64 = 30.0
    getter trial_wall_clock_seconds : Float64 = 120.0
    getter trial_max_rss_bytes : Int64 = 536_870_912
    getter max_conflict_retries : Int32 = 2
    getter max_drafts_per_day : Int32 = 8
    getter watch_window_events : Int32 = 500
    getter heldout_fraction : Float64 = 0.5
    getter replay_object_types : Array(String) = ["chat_input"]
    getter import_allow_list : Array(String) = DefaultImportAllow::LIST
    getter fixture_extra_allow : Array(String) = DefaultFixtureExtraAllow::LIST
    getter reserved_namespaces : Array(String) = DefaultReservedNamespaces::LIST
    getter reserved_paths : Array(String) = DefaultReservedPaths::LIST
    getter crystal_allowed_files : Array(String) = DefaultCrystalAllowedFiles::LIST
    getter crystal_require_allow : Array(String) = DefaultCrystalRequireAllow::LIST
    getter allowed_files : Array(String) = [
      "manifest.toml", "__init__.py", "object_types.py", "behaviors.py",
      "tools.py", "settings.py", "fixtures/run_fixtures.py",
      "fixtures/trial_scenario.py",
    ]

    def initialize(
      @enabled : Bool = false,
      @max_total_source_bytes : Int32 = 24_000,
      @max_file_bytes : Int32 = 12_000,
      @gap_failure_threshold : Int32 = 3,
      @trial_max_new_events : Int32 = 2_000,
      @trial_fixture_timeout_seconds : Float64 = 30.0,
      @trial_wall_clock_seconds : Float64 = 120.0,
      @trial_max_rss_bytes : Int64 = 536_870_912,
      @max_conflict_retries : Int32 = 2,
      @max_drafts_per_day : Int32 = 8,
      @watch_window_events : Int32 = 500,
      @heldout_fraction : Float64 = 0.5,
      @replay_object_types : Array(String) = ["chat_input"],
      @import_allow_list : Array(String) = DefaultImportAllow::LIST,
      @fixture_extra_allow : Array(String) = DefaultFixtureExtraAllow::LIST,
      @reserved_namespaces : Array(String) = DefaultReservedNamespaces::LIST,
      @reserved_paths : Array(String) = DefaultReservedPaths::LIST,
      @crystal_allowed_files : Array(String) = DefaultCrystalAllowedFiles::LIST,
      @crystal_require_allow : Array(String) = DefaultCrystalRequireAllow::LIST,
      @allowed_files : Array(String) = [
        "manifest.toml", "__init__.py", "object_types.py", "behaviors.py",
        "tools.py", "settings.py", "fixtures/run_fixtures.py",
        "fixtures/trial_scenario.py",
      ],
    )
    end
  end
end

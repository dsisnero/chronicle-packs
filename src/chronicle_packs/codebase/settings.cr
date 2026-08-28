require "json"

module Chronicle::Packs::Codebase
  # Settings for the Codebase Pack. Ported from upstream packs/codebase/
  # settings.py (CodebaseSettings). Controls issue→task auto-creation, ADR
  # path patterns, and dependency vulnerability flagging.
  struct CodebaseSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? auto_create_issues_as_tasks : Bool = true
    getter adr_path_patterns : Array(String) = ["adr/", "docs/adr", "decisions/", "doc/arch"]
    getter vulnerability_severity_threshold : String = "medium"
    getter max_files_per_repo : Int32 = 500
    getter supported_languages : Array(String) = ["python", "typescript", "javascript", "go", "rust", "java"]
    getter github_webhook_events : Array(String) = ["issues", "pull_request", "push", "create"]

    def initialize(
      @auto_create_issues_as_tasks : Bool = true,
      @adr_path_patterns : Array(String) = ["adr/", "docs/adr", "decisions/", "doc/arch"],
      @vulnerability_severity_threshold : String = "medium",
      @max_files_per_repo : Int32 = 500,
      @supported_languages : Array(String) = ["python", "typescript", "javascript", "go", "rust", "java"],
      @github_webhook_events : Array(String) = ["issues", "pull_request", "push", "create"],
    )
    end
  end
end

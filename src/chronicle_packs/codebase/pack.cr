require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Codebase Pack — repo ingestion, issue/PR tracking, ADR extraction, code
# change summarization, dependency auditing. Ported from upstream
# `packs/codebase` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# GitHub webhook / repo_file / repo_manifest sources become Repos; issue
# webhooks become Issues (with Core tasks when enabled); ADR-markdown files
# become ArchitectureDecisions; push/PR webhooks become CodeChanges; repo
# metadata dependencies become Dependency objects with severity-gated
# vulnerability flags. Composes with Core (tasks, derived_from_source).
module Chronicle::Packs::Codebase
  include Chronicle::Packs::DSL

  pack(
    name: "codebase",
    version: "0.1.2",
    description: "Codebase tracking: repo ingestion, issue/PR tracking, ADR extraction, code change summarization, dependency auditing. Provides 9 object types for engineering workflow visibility.",
    settings_schema: CodebaseSettings,
  )
end

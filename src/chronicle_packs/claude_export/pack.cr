require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"
require "./tools"

# Official Claude export importer pack. Ported from upstream
# `packs/importers/claude_export` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Parses conversations.json as a flat conversation list and emits strict
# Activity Normalizer acquired_item / acquired_content handoffs. Evidence
# identity, deduplication, extraction, and promotion remain normalizer-owned.
module Chronicle::Packs::ClaudeExport
  include Chronicle::Packs::DSL

  pack(
    name: "claude_export",
    version: "0.1.0",
    description: "Bounded deterministic ingestion of official Claude data exports, accepting the export ZIP or a bare conversations.json snapshot.",
    settings_schema: ClaudeExportSettings,
  )
end

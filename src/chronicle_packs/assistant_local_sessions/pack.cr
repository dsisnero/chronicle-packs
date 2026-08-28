require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"
require "./tools"

# Assistant Local Sessions importer pack. Ported from upstream
# `packs/importers/assistant_local_sessions` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Imports local agent-session JSONL logs (Claude Code projects/ and Codex
# sessions/ layouts) into Activity Normalizer's strict acquired-item contract,
# one record pair per user/assistant message line, inside a bounded
# most-recent-files window. The importer is a format adapter only: identity,
# deduplication, revisioning, evidence, and candidate extraction remain
# normalizer-owned.
module Chronicle::Packs::AssistantLocalSessions
  include Chronicle::Packs::DSL

  pack(
    name: "assistant_local_sessions",
    version: "0.1.0",
    description: "Bounded, deterministic ingestion of local agent-session JSONL logs (Claude Code and Codex), windowed to the most recent session files and parsed defensively against unversioned format drift.",
    settings_schema: AssistantLocalSessionsSettings,
  )
end

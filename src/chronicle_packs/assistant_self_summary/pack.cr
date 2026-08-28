require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"
require "./tools"

# Assistant self-summary importer pack. Ported from upstream
# `packs/importers/assistant_self_summary` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# One surface for the assistant-as-source seed: an owner pastes a
# self-summary (manual) or a connected assistant pushes the same text over
# MCP (mcp). The transport is connection-path metadata — the same summary
# through either transport produces the same evidence identity, because the
# dedup key is the canonical content hash. A self-summary is a lossy seed
# and its text is untrusted external content (injection-scanned on the way
# in).
module Chronicle::Packs::AssistantSelfSummary
  include Chronicle::Packs::DSL

  pack(
    name: "assistant_self_summary",
    version: "0.1.0",
    description: "Paste-back or MCP-pushed assistant self-summaries as evidence: one surface, transport as metadata, identity by canonical content hash, injection-scanned on ingestion.",
    settings_schema: AssistantSelfSummarySettings,
  )
end

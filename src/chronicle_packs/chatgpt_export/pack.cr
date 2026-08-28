require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"
require "./tools"

# Official ChatGPT export importer pack. Ported from upstream
# `packs/importers/chatgpt_export` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Parses conversations.json as a tree and emits strict Activity Normalizer
# acquired_item / acquired_content handoffs. Evidence identity,
# deduplication, extraction, and promotion remain normalizer-owned.
module Chronicle::Packs::ChatGPTExport
  include Chronicle::Packs::DSL

  pack(
    name: "chatgpt_export",
    version: "0.1.0",
    description: "Bounded deterministic ingestion of official ChatGPT export ZIPs, including canonical conversation paths and abandoned branches.",
    settings_schema: ChatGPTExportSettings,
  )
end

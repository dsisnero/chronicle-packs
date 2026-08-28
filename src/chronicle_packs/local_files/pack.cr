require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"
require "./tools"

# Local Files importer pack. Ported from upstream
# `packs/importers/local_files` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Loads a bounded directory snapshot into Activity Normalizer's
# acquired-item contract. The importer is a format adapter only: identity,
# deduplication, revisioning, evidence, and candidate extraction remain
# normalizer-owned.
module Chronicle::Packs::LocalFiles
  include Chronicle::Packs::DSL

  pack(
    name: "local_files",
    version: "0.1.0",
    description: "Bounded, deterministic directory snapshots for UTF-8 text, Markdown, and JSON, emitted through Activity Normalizer's acquired-item contract.",
    settings_schema: LocalFilesSettings,
  )
end

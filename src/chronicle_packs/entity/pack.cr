require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./behaviors"
require "./tools"

# Entity Pack — canonical, deduped real-world entities. Ported from
# upstream `packs/entity` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key.
module Chronicle::Packs::Entity
  include Chronicle::Packs::DSL

  pack(
    name: "entity",
    version: "0.1.2",
    description: "Canonical extraction and dedup for people/orgs/projects/products/repos. Entity mentions with provenance; dedup via merge candidates and decisions.",
    settings_schema: EntitySettings,
  )
end

require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"
require "./verification"

# Skills Pack — versioned, provenance-backed learned skills with a governed
# lifecycle. Ported from upstream `packs/skills` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no API key.
module Chronicle::Packs::Skills
  include Chronicle::Packs::DSL

  pack(
    name: "skills",
    version: "0.2.0",
    description: "Governed immutable learned-skill versions with idempotent invocation, promotion evidence, eligibility, and outcome summary.",
    settings_schema: SkillsSettings,
  )
end

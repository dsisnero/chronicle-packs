require "chronicle"

require "./core/settings"
require "./core/object_types"
require "./core/relation_types"
require "./core/behaviors"

# Core Pack v0.1 — the universal primitive substrate for all packs.
# Provides 7 object types, 7 (well, 8) relation types, and three
# deterministic behaviors. All behaviors run without an LLM or API key.
#
# Ported from upstream `packs/core/__init__.py` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0); the manifest-declared
# surface is verified against the live pack in spec/.
module Chronicle::Packs::Core
  include Chronicle::Packs::DSL

  pack(
    name: "core",
    version: "0.1.2",
    description: "Universal primitive substrate for all ActiveGraph packs. Provides 7 object types (source, observation, task, action, artifact, memory_candidate, evaluation) and 7 relation types. All behaviors are deterministic — no LLM or API key required.",
    settings_schema: CoreSettings,
  )
end

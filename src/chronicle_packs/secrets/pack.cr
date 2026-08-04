require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./managed"
require "./behaviors"
require "./tools"

# Secrets Pack — credential reference management (names only, never secret
# values), with auditable usage and managed sources behind the resolution
# seam. Ported from upstream `packs/secrets` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no API key.
module Chronicle::Packs::Secrets
  include Chronicle::Packs::DSL

  pack(
    name: "secrets",
    version: "0.2.0",
    description: "Credential reference management: scopes, credential refs (names only), usage and rotation audit. Environment-first resolution with managed source seam (OAuth device flow).",
    settings_schema: SecretsSettings,
  )
end

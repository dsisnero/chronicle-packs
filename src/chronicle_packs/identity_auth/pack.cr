require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./behaviors"
require "./tools"

# Identity/Auth Pack — principal resolution, role-based access, and
# permission checking. Ported from upstream `packs/identity_auth`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0). All behaviors are
# deterministic and run with no API key.
module Chronicle::Packs::IdentityAuth
  include Chronicle::Packs::DSL

  pack(
    name: "identity_auth",
    version: "0.2.1",
    description: "Identity and authorization: principal resolution, role-based access, and permission checking. Deterministic RBAC with an additive role hierarchy.",
    settings_schema: IdentitySettings,
  )
end

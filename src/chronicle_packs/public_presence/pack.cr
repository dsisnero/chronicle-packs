require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./html_text"
require "./tools"
require "./capabilities"
require "./behaviors"

# Public-presence bootstrap fetcher (ADR 0024 rung 1). Ported from upstream
# `packs/importers/public_presence` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# A gateway-routed, budgeted, R0 capability that fetches the owner's shared
# public handles (GitHub profile, personal site, X profile page) with the
# zero-key floor. Every fetch is a recorded capability call; every result is
# replay-retained (artifact mode) and injection-scanned before it lands as
# evidence on the `public_presence` surface.
module Chronicle::Packs::PublicPresence
  include Chronicle::Packs::DSL

  pack(
    name: "public_presence",
    version: "0.2.0",
    description: "Budgeted, gateway-routed R0 fetching of the owner's public handles; results land as injection-scanned, replay-retained evidence on the public_presence surface.",
    settings_schema: PublicPresenceSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(
        provider: "public_presence",
        capability: "fetch_page",
        risk_class: "low",
        credential_ref: "",
        action_class: "R0",
      ),
    ],
  )
end

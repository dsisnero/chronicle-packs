require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./sanitizer"
require "./untrusted"
require "./gateway"
require "./catalog"
require "./registration_check"
require "./standing_scopes"
require "./tools"
require "./integrations"
require "./capabilities"
require "./behaviors"

# Tool Gateway Pack — the host tool dispatch surface. Ported from upstream
# `packs/tool_gateway` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Slice 1: the object surface, capability registry, sanitizer, injection
# scan, policy decision, approval resolution, and the four core behaviors.
# Deferred: standing scopes (R2 auto-approval), integrations, LLM proxies,
# registration enforcement, and the reference web_fetch capability.
module Chronicle::Packs::ToolGateway
  include Chronicle::Packs::DSL

  pack(
    name: "tool_gateway",
    version: "0.1.0",
    description: "Normalizes, records, policy-checks, and executes external capability calls; maps results back to Core sources.",
    settings_schema: ToolGatewaySettings,
  )
end

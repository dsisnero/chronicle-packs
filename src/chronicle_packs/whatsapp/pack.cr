require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"
require "./capabilities"

# WhatsApp Adapter Pack — inbound Cloud API webhooks become chat_input
# (reusing the Chat Pack's conversation machinery); approved outbound replies
# become policy-checked Tool Gateway capability calls with the access token
# injected at execution time. Structurally the mirror of the Telegram
# Adapter Pack. Ported from upstream `packs/whatsapp` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::WhatsApp
  include Chronicle::Packs::DSL

  pack(
    name: "whatsapp",
    version: "0.2.0",
    description: "WhatsApp Cloud API transport adapter: inbound messages become chat_input (reusing the Chat Pack's conversation machinery); approved outbound replies become policy-checked Tool Gateway capability calls with the access token injected at execution time.",
    settings_schema: WhatsAppSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(
        provider: "whatsapp",
        capability: "send_message",
        risk_class: "low",
        credential_ref: "WHATSAPP_ACCESS_TOKEN",
        action_class: "R3",
      ),
    ],
  )
end

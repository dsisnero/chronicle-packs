require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"
require "./capabilities"
require "./poller"

# Telegram Adapter Pack — inbound updates become chat_input (reusing the Chat
# Pack's conversation machinery); approved outbound replies become policy-
# checked Tool Gateway capability calls with the bot token injected at
# execution time. Ported from upstream `packs/telegram` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::Telegram
  include Chronicle::Packs::DSL

  pack(
    name: "telegram",
    version: "0.2.0",
    description: "Telegram transport adapter: inbound updates become chat_input (reusing the Chat Pack's conversation machinery); approved outbound replies become policy-checked Tool Gateway capability calls with the bot token injected at execution time.",
    settings_schema: TelegramSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(
        provider: "telegram",
        capability: "send_message",
        risk_class: "low",
        credential_ref: "TELEGRAM_BOT_TOKEN",
        action_class: "R3",
      ),
    ],
  )
end

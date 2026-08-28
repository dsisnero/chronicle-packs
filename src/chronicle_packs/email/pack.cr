require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./behaviors"
require "./tools"

# Email Adapter Pack — inbound/outbound email adapter. Ported from upstream
# `packs/email` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Translates inbound emails into CommMessage(channel=email). email_ingester
# handles dedup, threading (In-Reply-To / References), and produces Source +
# CommMessage + EmailThread. reply_drafter formats EmailDraft.
# send_approver gates external sends with owner approval (policy:
# external_write_requires_owner_approval).
module Chronicle::Packs::Email
  include Chronicle::Packs::DSL

  pack(
    name: "email",
    version: "0.1.2",
    description: "Email adapter pack. Translates inbound emails into CommMessage(channel=email). email_ingester handles dedup, threading (In-Reply-To / References), and produces Source + CommMessage + EmailThread. reply_drafter formats EmailDraft. send_approver gates external sends with owner approval (policy: external_write_requires_owner_approval).",
    settings_schema: EmailSettings,
  )
end

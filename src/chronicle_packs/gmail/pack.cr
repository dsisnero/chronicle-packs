require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./family"
require "./tools"
require "./capabilities"
require "./control_plane"
require "./maintenance"
require "./behaviors"

# Gmail Pack — canonical Gmail service connector: budgeted exploration into a
# service/account profile, bounded replayable backfill, history-watermark
# polling, provider-neutral evidence, local conversation-family mapping with
# deterministic hygiene, local draft candidates, reversible draft writes, and
# R3-forever sends through an injected route adapter (Composio first). Ported
# from upstream `packs/gmail` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::Gmail
  include Chronicle::Packs::DSL

  pack(
    name: "gmail",
    version: "0.3.0",
    description: "Canonical Gmail service connector: budgeted exploration into a service/account profile, bounded replayable backfill, history-watermark polling, provider-neutral evidence, local conversation-family mapping with deterministic hygiene, local draft candidates, reversible draft writes, and R3-forever sends through an injected route adapter (Composio first).",
    settings_schema: GmailSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "drafts.create", risk_class: "medium", credential_ref: "", action_class: "R2"),
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "drafts.send", risk_class: "high", credential_ref: "", action_class: "R3"),
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "history.list", risk_class: "low", credential_ref: "", action_class: "R0"),
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "labels.list", risk_class: "low", credential_ref: "", action_class: "R0"),
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "messages.fetch", risk_class: "low", credential_ref: "", action_class: "R0"),
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "messages.get", risk_class: "low", credential_ref: "", action_class: "R0"),
      Chronicle::Packs::CapabilityDecl.new(provider: "gmail", capability: "profile.get", risk_class: "low", credential_ref: "", action_class: "R0"),
    ],
  )
end

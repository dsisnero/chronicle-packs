require "chronicle"

require "./object_types"
require "./relation_types"
require "./settings"
require "./author_frame"
require "./materialize"
require "./analysis"
require "./trial_driver"
require "./tools"
require "./behaviors"
require "./adopt"
require "./review"

# Evolution Pack v0.1 — self-modification with provenance: the assistant
# authors candidate packs, static gates check them without executing
# anything, fork trials run them against replayed history in isolation, a
# verified owner approves adoption through the gateway, and the runtime's
# quiescent promote adopts the trial's state. Every step is graph state;
# the bundle hash pins what was reviewed to what loads; disable is
# immediate deregistration plus boot-time exclusion.
#
# Shipped default: EvolutionSettings.enabled = False. Self-modification is
# opt-in, and adoption REFUSES to register without a verified approver or
# with a gateway policy that would auto-approve critical calls.
#
# Ported from upstream `packs/evolution` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Slice 1: the deterministic
# graph-native surface + behaviors + authoring tools; the Python-AST static
# gate pipeline, subprocess sandbox trials, and importlib materialization
# are deferred (see plans/parity.md).
module Chronicle::Packs::Evolution
  include Chronicle::Packs::DSL

  pack(
    name: "evolution",
    version: "0.8.0",
    description: "Agent-authored packs under governance: static gates, fork trials against replayed history, bundle-hash pins, verified owner approval, quiescent promote adoption, immediate disable. Ships disabled.",
    settings_schema: EvolutionSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(
        provider: "evolution",
        capability: "adopt_proposal",
        risk_class: "critical",
        credential_ref: "",
        action_class: "R4",
      ),
      Chronicle::Packs::CapabilityDecl.new(
        provider: "evolution",
        capability: "disable_promotion",
        risk_class: "high",
        credential_ref: "",
        action_class: "R4",
      ),
    ],
  )
end

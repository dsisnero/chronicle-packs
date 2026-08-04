require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Eval Outcome Pack — canonical terminal and maintenance outcomes with
# recency-aware artifact reliability. Ported from upstream
# `packs/eval_outcome` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key.
module Chronicle::Packs::EvalOutcome
  include Chronicle::Packs::DSL

  pack(
    name: "eval_outcome",
    version: "0.1.0",
    description: "Canonical terminal and maintenance outcomes with traceable, recency-aware artifact reliability and reversible eligibility hooks.",
    settings_schema: EvalOutcomeSettings,
  )
end

require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"
require "./capabilities"

# Schedule Pack — graph-native scheduling. Ported from upstream `packs/
# schedule` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Schedules declare WHEN to fire (interval | daily | once) and WHAT object
# to emit when they do; schedule_ticks are the event-first record that a
# due moment arrived. The pack owns NO clock and NO thread — a host driver
# injects timestamps via the emit_due_ticks tool. tick_router emits the
# schedule's payload; schedule_bookkeeper advances schedule state. The
# create_reminder capability makes "remind me at 9am" a policy-governed
# Tool Gateway call (action_class R3, per upstream ADR 0016 discipline).
module Chronicle::Packs::Schedule
  include Chronicle::Packs::DSL

  pack(
    name: "schedule",
    version: "0.2.0",
    description: "Graph-native scheduling: schedules declare when to fire and what to emit; ticks are event-first records of due moments; a host driver injects timestamps at the edge. No clock, no thread, no loop in the pack — proactive behavior without an orchestrator.",
    settings_schema: ScheduleSettings,
    capabilities: [
      Chronicle::Packs::CapabilityDecl.new(
        provider: "schedule",
        capability: "create_reminder",
        risk_class: "low",
        credential_ref: "",
        action_class: "R3",
      ),
    ],
  )
end

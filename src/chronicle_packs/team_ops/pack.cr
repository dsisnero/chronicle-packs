require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Team/Ops Pack — task triage, assignment, milestone tracking, workload
# estimation, completion verification. Ported from upstream `packs/team_ops`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# task_candidate observations become Core tasks; owner-ref'd tasks get
# Assignments (auto or manual); milestones group tasks; done observations
# produce CompletionEvidence and mark the task done. TeamTask wraps the Core
# task via relations — no separate object type. Composes with Core (task).
module Chronicle::Packs::TeamOps
  include Chronicle::Packs::DSL

  pack(
    name: "team_ops",
    version: "0.1.2",
    description: "Team project management: task triage, assignment, milestone tracking, workload estimation, and completion verification. Extends Core task with 6 project management object types.",
    settings_schema: TeamOpsSettings,
  )
end

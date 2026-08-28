require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Subject Profile Pack — evidence-backed, explicitly reviewed subject facts
# with contradiction and supersession lifecycles. Ported from upstream
# `packs/subject_profile` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# An explicit review decision over an activity_normalizer `profile_candidate`
# promotes an owner-scoped `subject_fact` (guarded by evidence scope), or
# rejects/invalidates the candidate; conflicting owner-confirmed values
# record `subject_contradiction`s. Forgetting supersedes a fact via an
# auditable tombstone.
module Chronicle::Packs::SubjectProfile
  include Chronicle::Packs::DSL

  pack(
    name: "subject_profile",
    version: "0.1.0",
    description: "Evidence-backed, explicitly reviewed subject facts with contradiction and supersession lifecycles.",
    settings_schema: SubjectProfileSettings,
  )
end

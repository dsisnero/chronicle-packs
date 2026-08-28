require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./tools"
require "./behaviors"

# Meeting Pack — transcript ingestion, decision extraction, action item
# extraction with Core task creation, and meeting summarization. Ported from
# upstream `packs/meeting` (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# A meeting_transcript source becomes a Meeting + TranscriptSegments; flagged
# segments become MeetingDecisions and MeetingActionItems (with Core tasks);
# meeting.created auto-generates a summary MeetingNote. All v0.1 behaviors are
# deterministic mock stubs. Composes with Core (source, task).
module Chronicle::Packs::Meeting
  include Chronicle::Packs::DSL

  pack(
    name: "meeting",
    version: "0.1.2",
    description: "Meeting ingestion and processing: transcript parsing (structured and plain text), decision extraction, action item extraction with Core task creation, and meeting summarization. Provides 5 meeting-domain object types.",
    settings_schema: MeetingSettings,
  )
end

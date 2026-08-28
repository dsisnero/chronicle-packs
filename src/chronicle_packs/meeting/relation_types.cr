module Chronicle::Packs::Meeting
  # Meeting Pack relation types. Ported from upstream
  # packs/meeting/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "segment_of", source_types: ["transcript_segment"], target_types: ["meeting"], description: "TranscriptSegment belongs to a Meeting.")]
  struct SegmentOf
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "decision_in", source_types: ["meeting_decision"], target_types: ["meeting"], description: "Decision made in a Meeting.")]
  struct DecisionIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "action_item_in", source_types: ["meeting_action_item"], target_types: ["meeting"], description: "ActionItem identified in a Meeting.")]
  struct ActionItemIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "note_for", source_types: ["meeting_note"], target_types: ["meeting"], description: "Note written for a Meeting.")]
  struct NoteFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "decision_from_segment", source_types: ["meeting_decision"], target_types: ["transcript_segment"], description: "Decision extracted from a specific segment.")]
  struct DecisionFromSegment
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "action_item_from_segment", source_types: ["meeting_action_item"], target_types: ["transcript_segment"], description: "Action item extracted from a specific segment.")]
  struct ActionItemFromSegment
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "action_creates_task", source_types: ["meeting_action_item"], target_types: ["task"], description: "Meeting action item promoted to a Core task.")]
  struct ActionCreatesTask
  end
end

require "json"

module Chronicle::Packs::Meeting
  # Settings for the Meeting Pack. Ported from upstream packs/meeting/
  # settings.py (MeetingSettings). Controls task auto-creation, decision/
  # action-item keyword detection, segment filtering, and auto-summarization.
  struct MeetingSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? auto_create_tasks_from_action_items : Bool = true
    getter decision_keywords : Array(String) = [
      "decided", "we agreed", "agreed to", "we will", "action item",
      "going forward", "resolved", "confirmed", "approved", "we're going",
      "let's", "let us", "we decided", "consensus", "unanimous",
    ]
    getter action_item_keywords : Array(String) = [
      "will", "action item", "follow up", "to do", "todo", "needs to",
      "should", "by next", "owner:", "due:", "take care of",
      "responsible for", "assigned to", "going to", "i'll", "you'll",
      "we'll", "they'll",
    ]
    getter min_segment_words : Int32 = 5
    getter? auto_summarize_meeting : Bool = true
    getter max_segments_per_meeting : Int32 = 500

    def initialize(
      @auto_create_tasks_from_action_items : Bool = true,
      @decision_keywords : Array(String) = [
        "decided", "we agreed", "agreed to", "we will", "action item",
        "going forward", "resolved", "confirmed", "approved", "we're going",
        "let's", "let us", "we decided", "consensus", "unanimous",
      ],
      @action_item_keywords : Array(String) = [
        "will", "action item", "follow up", "to do", "todo", "needs to",
        "should", "by next", "owner:", "due:", "take care of",
        "responsible for", "assigned to", "going to", "i'll", "you'll",
        "we'll", "they'll",
      ],
      @min_segment_words : Int32 = 5,
      @auto_summarize_meeting : Bool = true,
      @max_segments_per_meeting : Int32 = 500,
    )
    end
  end
end

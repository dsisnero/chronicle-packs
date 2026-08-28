require "json"

module Chronicle::Packs::Meeting
  # Meeting Pack object types. Ported from upstream packs/meeting/
  # object_types.py. 5 meeting-domain primitives extending Core.

  # Closed Literal sets for the meeting surface (AGENTS.md: closed string
  # sets are enums; non-flags enums round-trip via the underscore name).

  # Meeting.platform — upstream Literal["zoom", "teams", "google_meet",
  # "in_person", "phone", "other"].
  enum MeetingPlatform
    Zoom
    Teams
    GoogleMeet
    InPerson
    Phone
    Other
  end

  # Meeting.status — upstream Literal["scheduled", "completed", "cancelled"].
  enum MeetingStatus
    Scheduled
    Completed
    Cancelled
  end

  # MeetingActionItem.status — upstream Literal["open", "done", "cancelled"].
  enum ActionItemStatus
    Open
    Done
    Cancelled
  end

  # MeetingNote.note_type — upstream Literal["summary", "minutes",
  # "highlights", "raw"].
  enum NoteType
    Summary
    Minutes
    Highlights
    Raw
  end

  # A meeting with participants, platform, and transcript source.
  @[Chronicle::Packs::Annotations::ObjectType(name: "meeting", description: "A meeting with participants, platform, and transcript source.")]
  struct Meeting
    include JSON::Serializable

    getter title : String
    getter date : String? = nil
    getter duration_minutes : Int32? = nil
    getter platform : MeetingPlatform = MeetingPlatform::Other
    getter participants : Array(String) = [] of String
    getter recording_url : String? = nil
    getter source_id : String? = nil
    getter status : MeetingStatus = MeetingStatus::Completed
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @title : String,
      @date : String? = nil,
      @duration_minutes : Int32? = nil,
      @platform : MeetingPlatform = MeetingPlatform::Other,
      @participants : Array(String) = [] of String,
      @recording_url : String? = nil,
      @source_id : String? = nil,
      @status : MeetingStatus = MeetingStatus::Completed,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A segment of a meeting transcript (one speaker turn).
  @[Chronicle::Packs::Annotations::ObjectType(name: "transcript_segment", description: "A segment of a meeting transcript (one speaker turn).")]
  struct TranscriptSegment
    include JSON::Serializable

    getter meeting_id : String
    getter speaker : String
    getter text : String
    getter timestamp_seconds : Float64? = nil
    getter segment_index : Int32 = 0
    getter? is_decision : Bool = false
    getter? is_action_item : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @meeting_id : String,
      @speaker : String,
      @text : String,
      @timestamp_seconds : Float64? = nil,
      @segment_index : Int32 = 0,
      @is_decision : Bool = false,
      @is_action_item : Bool = false,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A decision made during a meeting.
  @[Chronicle::Packs::Annotations::ObjectType(name: "meeting_decision", description: "A decision made during a meeting.")]
  struct MeetingDecision
    include JSON::Serializable

    getter meeting_id : String
    getter text : String
    getter segment_id : String? = nil
    getter decided_by : Array(String) = [] of String
    getter confidence : Float64 = 0.8
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @meeting_id : String,
      @text : String,
      @segment_id : String? = nil,
      @decided_by : Array(String) = [] of String,
      @confidence : Float64 = 0.8,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # An action item identified in a meeting (linked to Core task).
  @[Chronicle::Packs::Annotations::ObjectType(name: "meeting_action_item", description: "An action item identified in a meeting (linked to Core task).")]
  struct MeetingActionItem
    include JSON::Serializable

    getter meeting_id : String
    getter text : String
    getter owner_ref : String? = nil
    getter due_at : String? = nil
    getter segment_id : String? = nil
    getter task_id : String? = nil
    getter status : ActionItemStatus = ActionItemStatus::Open
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @meeting_id : String,
      @text : String,
      @owner_ref : String? = nil,
      @due_at : String? = nil,
      @segment_id : String? = nil,
      @task_id : String? = nil,
      @status : ActionItemStatus = ActionItemStatus::Open,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A note or summary of a meeting.
  @[Chronicle::Packs::Annotations::ObjectType(name: "meeting_note", description: "A note or summary of a meeting.")]
  struct MeetingNote
    include JSON::Serializable

    getter meeting_id : String
    getter content : String
    getter note_type : NoteType = NoteType::Summary
    getter artifact_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @meeting_id : String,
      @content : String,
      @note_type : NoteType = NoteType::Summary,
      @artifact_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

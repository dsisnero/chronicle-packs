require "json"

module Chronicle::Packs::Communication
  # Communication object types. Ported from upstream
  # packs/communication/object_types.py.
  #
  # Channel-neutral communication primitives (the comm_* action layer) plus
  # the durable conversation-family contract (conversation_*). Upstream is
  # Pydantic (extra="forbid" on the family models); JSON::Serializable
  # ignores unknown fields.

  # Closed string-literal sets for the communication surface.

  enum ThreadStatus
    Open
    Closed
    Archived
  end

  enum MessageDirection
    Inbound
    Outbound
  end

  enum UnknownableDirection
    Inbound
    Outbound
    Unknown
  end

  enum IntentKind
    Query
    Request
    Reply
    Notification
    Review
    ApprovalRequest
    Unknown
  end

  enum ResponseStatus
    Draft
    Proposed
    Approved
    Sent
    Rejected
  end

  enum ParticipantRole
    Sender
    Recipient
    Cc
    Observer
    Bcc
  end

  enum MessageKind
    Human
    Notification
    Automated
    Unknown
  end

  enum InterpretationState
    Ready
    Held
    Suppressed
    Empty
  end

  enum InterpretationRunStatus
    Selected
    DeterministicOnly
    Completed
    Held
    Suppressed
    Failed
    Invalidated
  end

  # A channel-specific conversation thread.
  @[Chronicle::Packs::Annotations::ObjectType(name: "comm_thread", description: "A channel-specific conversation thread. Container for related messages. Created by thread_tracker on first message in a new thread.")]
  struct CommThread
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter channel : String
    getter subject : String? = nil
    getter participant_ids : Array(String) = [] of String
    getter status : ThreadStatus = ThreadStatus::Open
    getter created_at : String = ""
    getter last_message_at : String? = nil
    getter message_count : Int32 = 0
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @channel : String,
      @subject : String? = nil, @participant_ids : Array(String) = [] of String,
      @status : ThreadStatus = ThreadStatus::Open, @created_at : String = "",
      @last_message_at : String? = nil, @message_count : Int32 = 0,
      @frame_id : String? = nil, @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A channel-neutral message in a communication thread.
  @[Chronicle::Packs::Annotations::ObjectType(name: "comm_message", description: "A channel-neutral message. All adapters (Chat, Email) translate inputs into CommMessage so domain packs can process them uniformly.")]
  struct CommMessage
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter thread_id : String? = nil
    getter channel : String
    getter sender_ref : String = ""
    getter content : String = ""
    getter intent_hint : String? = nil
    getter direction : MessageDirection = MessageDirection::Inbound
    getter source_id : String? = nil
    getter created_at : String = ""
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @channel : String,
      @thread_id : String? = nil, @sender_ref : String = "", @content : String = "",
      @intent_hint : String? = nil, @direction : MessageDirection = MessageDirection::Inbound,
      @source_id : String? = nil, @created_at : String = "", @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # The classified intent of an inbound CommMessage.
  @[Chronicle::Packs::Annotations::ObjectType(name: "comm_intent", description: "Classified intent of an inbound CommMessage: query/request/reply/notification/review/approval_request/unknown. Created by intent_detector.")]
  struct CommIntent
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter message_id : String
    getter thread_id : String? = nil
    getter intent : IntentKind = IntentKind::Unknown
    getter confidence : Float64 = 0.7
    getter reasoning : String = ""
    getter secondary_intent : String? = nil
    getter detected_by : String = "intent_detector"
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @message_id : String,
      @thread_id : String? = nil, @intent : IntentKind = IntentKind::Unknown,
      @confidence : Float64 = 0.7, @reasoning : String = "", @secondary_intent : String? = nil,
      @detected_by : String = "intent_detector", @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A candidate response to an inbound message, pending approval or dispatch.
  @[Chronicle::Packs::Annotations::ObjectType(name: "comm_response_candidate", description: "Candidate response to an inbound message. Lifecycle: draft -> proposed -> approved -> sent (or rejected). Dispatched by response_dispatcher on approved.")]
  struct CommResponseCandidate
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter message_id : String
    getter thread_id : String? = nil
    getter channel : String
    getter content : String = ""
    getter artifact_id : String? = nil
    getter status : ResponseStatus = ResponseStatus::Draft
    getter created_by_behavior : String = ""
    getter rejection_reason : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @message_id : String, @channel : String,
      @thread_id : String? = nil, @content : String = "", @artifact_id : String? = nil,
      @status : ResponseStatus = ResponseStatus::Draft, @created_by_behavior : String = "",
      @rejection_reason : String? = nil, @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A participant in a CommThread with a role.
  @[Chronicle::Packs::Annotations::ObjectType(name: "comm_participant", description: "A participant in a CommThread with a role (sender/recipient/cc/observer). Links principal_ref to thread without embedding identity in CommThread.")]
  struct CommParticipant
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter thread_id : String
    getter principal_ref : String
    getter role : ParticipantRole = ParticipantRole::Recipient
    getter joined_at : String = ""
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @thread_id : String, @principal_ref : String,
      @role : ParticipantRole = ParticipantRole::Recipient, @joined_at : String = "",
      @frame_id : String? = nil, @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A durable connector-family conversation thread.
  @[Chronicle::Packs::Annotations::ObjectType(name: "conversation_thread", description: "A durable connector-family conversation thread.")]
  struct ConversationThread
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter thread_identity : String
    getter source_surface_id : String
    getter service : String
    getter account_ref : String
    getter provider_thread_id : String
    getter subject : String = ""
    getter participant_ids : Array(String) = [] of String
    getter message_ids : Array(String) = [] of String
    getter status : ThreadStatus = ThreadStatus::Open
    getter last_message_at : String? = nil
    getter unread_count : Int32 = 0
    getter message_count : Int32 = 0
    getter labels : Array(String) = [] of String
    getter refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @thread_identity : String, @source_surface_id : String, @service : String,
      @account_ref : String, @provider_thread_id : String, @subject : String = "",
      @participant_ids : Array(String) = [] of String, @message_ids : Array(String) = [] of String,
      @status : ThreadStatus = ThreadStatus::Open, @last_message_at : String? = nil,
      @unread_count : Int32 = 0, @message_count : Int32 = 0, @labels : Array(String) = [] of String,
      @refs : Array(String) = [] of String, @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A service-neutral message with deterministic hygiene and evidence provenance.
  @[Chronicle::Packs::Annotations::ObjectType(name: "conversation_message", description: "A service-neutral message with deterministic hygiene and evidence provenance.")]
  struct ConversationMessage
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter message_identity : String
    getter thread_id : String
    getter source_surface_id : String
    getter service : String
    getter account_ref : String
    getter provider_message_id : String
    getter provider_revision_ref : String
    getter internet_message_id : String? = nil
    getter sender : String? = nil
    getter recipients : Array(String) = [] of String
    getter cc : Array(String) = [] of String
    getter subject : String = ""
    getter sent_at : String? = nil
    getter direction : UnknownableDirection = UnknownableDirection::Unknown
    getter message_kind : MessageKind = MessageKind::Unknown
    getter labels : Array(String) = [] of String
    getter? unread : Bool = false
    getter display_content : String = ""
    getter interpretation_content : String = ""
    getter interpretation_state : InterpretationState = InterpretationState::Empty
    getter suppression_counts : Hash(String, Int32) = {} of String => Int32
    getter injection_flags : Array(String) = [] of String
    getter evidence_id : String
    getter refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @message_identity : String, @thread_id : String, @source_surface_id : String,
      @service : String, @account_ref : String, @provider_message_id : String,
      @provider_revision_ref : String, @evidence_id : String,
      @internet_message_id : String? = nil, @sender : String? = nil,
      @recipients : Array(String) = [] of String, @cc : Array(String) = [] of String,
      @subject : String = "", @sent_at : String? = nil,
      @direction : UnknownableDirection = UnknownableDirection::Unknown,
      @message_kind : MessageKind = MessageKind::Unknown, @labels : Array(String) = [] of String,
      @unread : Bool = false, @display_content : String = "", @interpretation_content : String = "",
      @interpretation_state : InterpretationState = InterpretationState::Empty,
      @suppression_counts : Hash(String, Int32) = {} of String => Int32,
      @injection_flags : Array(String) = [] of String, @refs : Array(String) = [] of String,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A normalized participant in a conversation thread.
  @[Chronicle::Packs::Annotations::ObjectType(name: "conversation_participant", description: "A normalized participant in a conversation thread.")]
  struct ConversationParticipant
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter participant_identity : String
    getter thread_id : String
    getter address : String
    getter display_name : String = ""
    getter roles : Array(ParticipantRole) = [] of ParticipantRole
    getter entity_mention_id : String? = nil
    getter entity_id : String? = nil
    getter refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @participant_identity : String, @thread_id : String, @address : String,
      @display_name : String = "", @roles : Array(ParticipantRole) = [] of ParticipantRole,
      @entity_mention_id : String? = nil, @entity_id : String? = nil,
      @refs : Array(String) = [] of String, @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # Exact contiguous selector into authoritative evidence.
  struct ConversationSelection
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter start : Int32
    getter end : Int32
    getter exact_hash : String

    def initialize(@start : Int32, @end : Int32, @exact_hash : String)
    end

    define_copy_with
  end

  # One pinned staged interpretation over evidence-selected segments.
  @[Chronicle::Packs::Annotations::ObjectType(name: "conversation_interpretation_run", description: "One pinned staged interpretation over evidence-selected segments.")]
  struct ConversationInterpretationRun
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter run_identity : String
    getter message_id : String
    getter evidence_id : String
    getter evidence_revision_id : String
    getter selection_id : String
    getter deterministic_filter_version : String
    getter family_projector_version : String
    getter extraction_profile_id : String? = nil
    getter extractor_refs : Array(String) = [] of String
    getter requested_facets : Array(String) = [] of String
    getter semantic_request_id : String? = nil
    getter selections : Array(ConversationSelection) = [] of ConversationSelection
    getter selected_chars : Int32 = 0
    getter selected_content_hash : String
    getter status : InterpretationRunStatus = InterpretationRunStatus::Selected
    getter semantic_run_ids : Array(String) = [] of String
    getter annotation_ids : Array(String) = [] of String
    getter coverage : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter suppression_counts : Hash(String, Int32) = {} of String => Int32
    getter reprocess_of : String? = nil
    getter error : String? = nil
    getter refs : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @run_identity : String, @message_id : String, @evidence_id : String,
      @evidence_revision_id : String, @selection_id : String,
      @deterministic_filter_version : String, @family_projector_version : String,
      @selected_content_hash : String,
      @extraction_profile_id : String? = nil, @extractor_refs : Array(String) = [] of String,
      @requested_facets : Array(String) = [] of String, @semantic_request_id : String? = nil,
      @selections : Array(ConversationSelection) = [] of ConversationSelection,
      @selected_chars : Int32 = 0, @status : InterpretationRunStatus = InterpretationRunStatus::Selected,
      @semantic_run_ids : Array(String) = [] of String, @annotation_ids : Array(String) = [] of String,
      @coverage : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @suppression_counts : Hash(String, Int32) = {} of String => Int32,
      @reprocess_of : String? = nil, @error : String? = nil, @refs : Array(String) = [] of String,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end
end

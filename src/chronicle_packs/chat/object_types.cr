require "json"

module Chronicle::Packs::Chat
  # Chat Adapter Pack object types. Ported from upstream
  # packs/chat/object_types.py.
  #
  # Chat-specific types that complement the channel-neutral Communication
  # Pack. The Chat Pack owns the chat-specific UX objects (session, turn,
  # raw input); chat_ingester translates ChatInput → CommMessage so
  # Communication Pack behaviors can process it.

  # Session lifecycle status (upstream Literal["active", "idle", "closed"]).
  enum SessionStatus
    Active
    Idle
    Closed
  end

  # Raw input received from a chat interface. ChatInput is the entry point
  # for the Chat adapter; chat_ingester fires on chat_input.created and
  # translates it into a CommMessage (channel=chat).
  @[Chronicle::Packs::Annotations::ObjectType(name: "chat_input", description: "Raw input from a chat interface. chat_ingester fires on chat_input.created and translates it into CommMessage(channel=chat).")]
  struct ChatInput
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter user_ref : String
    getter content : String
    getter session_id : String? = nil
    getter frame_id : String? = nil
    getter role : String = "user"
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @user_ref : String,
      @content : String,
      @session_id : String? = nil,
      @frame_id : String? = nil,
      @role : String = "user",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # A persistent chat session between a user and the assistant. Groups
  # multiple ChatTurns into a coherent conversation and links to a
  # CommThread for the channel-neutral view. Sessions persist across turns
  # and can be resumed with session_id.
  @[Chronicle::Packs::Annotations::ObjectType(name: "chat_session", description: "A persistent chat session grouping multiple ChatTurns. Links to a CommThread for the channel-neutral view.")]
  struct ChatSession
    include JSON::Serializable

    getter user_ref : String
    getter started_at : String = ""
    getter ended_at : String? = nil
    getter status : SessionStatus = SessionStatus::Active
    getter thread_id : String? = nil
    getter turn_count : Int32 = 0
    getter llm_config : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @user_ref : String,
      @started_at : String = "",
      @ended_at : String? = nil,
      @status : SessionStatus = SessionStatus::Active,
      @thread_id : String? = nil,
      @turn_count : Int32 = 0,
      @llm_config : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A single request-response turn in a ChatSession. user_message is set on
  # creation; assistant_message is populated when a CommResponseCandidate
  # is delivered. Turn numbers are 1-indexed.
  @[Chronicle::Packs::Annotations::ObjectType(name: "chat_turn", description: "A single request-response exchange in a ChatSession. user_message is set on creation; assistant_message is populated after delivery.")]
  struct ChatTurn
    include JSON::Serializable

    getter session_id : String
    getter user_message : String
    getter assistant_message : String? = nil
    getter turn_number : Int32 = 1
    getter comm_message_id : String? = nil
    getter response_candidate_id : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @session_id : String,
      @user_message : String,
      @assistant_message : String? = nil,
      @turn_number : Int32 = 1,
      @comm_message_id : String? = nil,
      @response_candidate_id : String? = nil,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Graph-native conversation memory for one inbound message. Assembled by
  # chat_context_assembler from prior ChatTurns in the graph (linked to the
  # session via session_contains_turn) and read by chat_llm_responder as the
  # conversation history shown to the LLM. Reconstructed from persisted graph
  # objects on every turn, so it requires no in-process state and survives a
  # restart mid-session.
  @[Chronicle::Packs::Annotations::ObjectType(name: "chat_context", description: "Graph-native conversation memory for one inbound message. Assembled by chat_context_assembler from prior ChatTurns and read by chat_llm_responder as the conversation history shown to the LLM.")]
  struct ChatContext
    include JSON::Serializable

    getter session_id : String
    getter message_id : String
    getter turn_count : Int32 = 0
    getter transcript : String = ""
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Long-term memory recalled for one inbound message. chat_memory_context
  # queries the Memory Gateway backend for memories relevant to the inbound
  # message and writes the top matches here, linked to the CommMessage via
  # provides_context_for. It is the "use" half of long-term memory, riding
  # into the LLM prompt that is the responder's depth-1 scoped view.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_context", description: "Long-term memory recalled for one inbound message. Assembled by chat_memory_context from the Memory Gateway backend and read by chat_llm_responder as durable cross-session memory shown to the LLM.")]
  struct MemoryContext
    include JSON::Serializable

    getter message_id : String
    getter query : String = ""
    getter item_count : Int32 = 0
    getter item_ids : Array(String) = [] of String
    getter summary : String = ""
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

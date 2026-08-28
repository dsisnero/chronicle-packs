require "json"

module Chronicle::Packs::Email
  # Email Pack object types. Ported from upstream packs/email/object_types.py.
  #
  # Email-specific types that complement the channel-neutral Communication
  # Pack. EmailMessage captures channel-specific structure (headers, MIME,
  # threading references); email_ingester translates it into Core Source +
  # CommMessage(channel=email) + EmailThread so communication/domain pack
  # behaviors process emails uniformly.

  # A raw inbound email message.
  @[Chronicle::Packs::Annotations::ObjectType(name: "email_message", description: "A raw inbound email. email_ingester fires on email_message.created and produces Source + CommMessage + EmailThread.")]
  struct EmailMessage
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter message_id : String
    getter from_addr : String
    getter to_addrs : Array(String) = [] of String
    getter cc_addrs : Array(String) = [] of String
    getter subject : String = ""
    getter body_text : String = ""
    getter body_html : String? = nil
    getter thread_id : String? = nil
    getter in_reply_to : String? = nil
    getter references : Array(String) = [] of String
    getter received_at : String = ""
    getter headers : Hash(String, String) = {} of String => String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @message_id : String,
      @from_addr : String,
      @to_addrs : Array(String) = [] of String,
      @cc_addrs : Array(String) = [] of String,
      @subject : String = "",
      @body_text : String = "",
      @body_html : String? = nil,
      @thread_id : String? = nil,
      @in_reply_to : String? = nil,
      @references : Array(String) = [] of String,
      @received_at : String = "",
      @headers : Hash(String, String) = {} of String => String,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # An email thread grouping related messages by In-Reply-To / References.
  @[Chronicle::Packs::Annotations::ObjectType(name: "email_thread", description: "An email thread grouping related messages by In-Reply-To / References. Created/updated by email_ingester.")]
  struct EmailThread
    include JSON::Serializable

    getter thread_id : String
    getter subject : String = ""
    getter participant_addrs : Array(String) = [] of String
    getter message_count : Int32 = 0
    getter last_message_at : String = ""
    getter first_message_id : String? = nil
    getter comm_thread_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @thread_id : String,
      @subject : String = "",
      @participant_addrs : Array(String) = [] of String,
      @message_count : Int32 = 0,
      @last_message_at : String = "",
      @first_message_id : String? = nil,
      @comm_thread_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A draft outbound email produced by reply_drafter.
  @[Chronicle::Packs::Annotations::ObjectType(name: "email_draft", description: "A draft outbound email created by reply_drafter. send_approver gates delivery. Lifecycle: draft → approved/rejected → sent.")]
  struct EmailDraft
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter to_addrs : Array(String) = [] of String
    getter cc_addrs : Array(String) = [] of String
    getter subject : String = ""
    getter body : String = ""
    getter in_reply_to_message_id : String? = nil
    getter response_candidate_id : String? = nil
    getter artifact_id : String? = nil
    getter status : String = "draft"
    getter? requires_approval : Bool = true
    getter rejection_reason : String? = nil
    getter sent_at : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @to_addrs : Array(String) = [] of String,
      @cc_addrs : Array(String) = [] of String,
      @subject : String = "",
      @body : String = "",
      @in_reply_to_message_id : String? = nil,
      @response_candidate_id : String? = nil,
      @artifact_id : String? = nil,
      @status : String = "draft",
      @requires_approval : Bool = true,
      @rejection_reason : String? = nil,
      @sent_at : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end
end

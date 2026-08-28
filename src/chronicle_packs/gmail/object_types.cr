require "json"

module Chronicle::Packs::Gmail
  # Gmail-specific sync and local-draft state; evidence stays provider-neutral.
  # Ported from upstream packs/gmail/object_types.py.

  # Closed Literal sets for the Gmail surface (AGENTS.md: closed string sets
  # are enums; non-flags enums round-trip via the underscore name).

  # GmailSyncRun.mode — upstream Literal["backfill", "poll"].
  enum SyncMode
    Backfill
    Poll
  end

  # GmailSyncRun.status — upstream Literal["proposed", "running", "completed",
  # "partial", "failed"].
  enum SyncStatus
    Proposed
    Running
    Completed
    Partial
    Failed
  end

  # GmailSyncRun.error_code — upstream Literal["rate_limited", "auth_expired",
  # "cursor_invalid", "unexpected_shape", "provider_failed"].
  enum ErrorCode
    RateLimited
    AuthExpired
    CursorInvalid
    UnexpectedShape
    ProviderFailed
  end

  # GmailDraftCandidate.status — upstream Literal["local_draft",
  # "sync_proposed", "synced", "send_proposed", "sent", "rejected"].
  enum DraftStatus
    LocalDraft
    SyncProposed
    Synced
    SendProposed
    Sent
    Rejected
  end

  # One bounded Gmail backfill or history-poll run.
  @[Chronicle::Packs::Annotations::ObjectType(name: "gmail_sync_run", description: "One bounded Gmail backfill or history-poll run.")]
  struct GmailSyncRun
    include JSON::Serializable

    getter run_identity : String
    getter source_surface_id : String
    getter account_ref : String
    getter user_id : String
    getter connected_account_id : String
    getter mode : SyncMode
    getter query : String = ""
    getter start_history_id : String? = nil
    getter next_page_token : String? = nil
    getter page_size : Int32
    getter max_messages : Int32
    getter max_pages : Int32
    getter pages_completed : Int32 = 0
    getter messages_imported : Int32 = 0
    getter call_ids : Array(String) = [] of String
    getter pending_message_ids : Array(String) = [] of String
    getter completed_message_ids : Array(String) = [] of String
    getter missing_message_ids : Array(String) = [] of String
    getter status : SyncStatus = SyncStatus::Proposed
    getter latest_history_id : String? = nil
    getter deleted_message_ids : Array(String) = [] of String
    getter tombstones_recorded : Int32 = 0
    getter error_code : ErrorCode? = nil
    getter error : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @run_identity : String,
      @source_surface_id : String,
      @account_ref : String,
      @user_id : String,
      @connected_account_id : String,
      @mode : SyncMode,
      @page_size : Int32,
      @max_messages : Int32,
      @max_pages : Int32,
      @query : String = "",
      @start_history_id : String? = nil,
      @next_page_token : String? = nil,
      @pages_completed : Int32 = 0,
      @messages_imported : Int32 = 0,
      @call_ids : Array(String) = [] of String,
      @pending_message_ids : Array(String) = [] of String,
      @completed_message_ids : Array(String) = [] of String,
      @missing_message_ids : Array(String) = [] of String,
      @status : SyncStatus = SyncStatus::Proposed,
      @latest_history_id : String? = nil,
      @deleted_message_ids : Array(String) = [] of String,
      @tombstones_recorded : Int32 = 0,
      @error_code : ErrorCode? = nil,
      @error : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A local R1 draft before any Gmail write or send.
  @[Chronicle::Packs::Annotations::ObjectType(name: "gmail_draft_candidate", description: "A local R1 draft before any Gmail write or send.")]
  struct GmailDraftCandidate
    include JSON::Serializable

    getter draft_identity : String
    getter account_ref : String
    getter connected_account_id : String
    getter to : Array(String) = [] of String
    getter cc : Array(String) = [] of String
    getter bcc : Array(String) = [] of String
    getter subject : String = ""
    getter body : String = ""
    getter thread_id : String? = nil
    getter status : DraftStatus = DraftStatus::LocalDraft
    getter provider_draft_id : String? = nil
    getter prediction_id : String? = nil
    getter idempotency_key : String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @draft_identity : String,
      @account_ref : String,
      @connected_account_id : String,
      @idempotency_key : String,
      @to : Array(String) = [] of String,
      @cc : Array(String) = [] of String,
      @bcc : Array(String) = [] of String,
      @subject : String = "",
      @body : String = "",
      @thread_id : String? = nil,
      @status : DraftStatus = DraftStatus::LocalDraft,
      @provider_draft_id : String? = nil,
      @prediction_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

require "json"

module Chronicle::Packs::Email
  # Settings for the Email Pack. Ported from upstream
  # packs/email/settings.py (EmailSettings). Controls ingestion, draft
  # formatting, and the external-send approval gate.
  struct EmailSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? require_approval_for_external : Bool = true
    getter? auto_create_threads : Bool = true
    getter trusted_domains : Array(String) = [] of String
    getter draft_signature : String = ""
    getter max_body_length : Int32 = 50_000
    getter default_reply_format : String = "plain_text"
    getter owner_email_addresses : Array(String) = [] of String

    def initialize(
      @require_approval_for_external : Bool = true,
      @auto_create_threads : Bool = true,
      @trusted_domains : Array(String) = [] of String,
      @draft_signature : String = "",
      @max_body_length : Int32 = 50_000,
      @default_reply_format : String = "plain_text",
      @owner_email_addresses : Array(String) = [] of String,
    )
    end
  end
end

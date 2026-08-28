require "json"

module Chronicle::Packs::Telegram
  # Telegram Adapter Pack object types. Ported from upstream
  # packs/telegram/object_types.py. One object type: the raw inbound update,
  # injected at the edge by a driver (long-poller or webhook receiver).
  # Everything conversational happens in the Chat Pack — this pack is a
  # transport adapter, nothing more.

  # A raw inbound Telegram update, as injected by the driver.
  #
  # Only the fields the adapter needs are lifted out; the trimmed original
  # lives in ``raw`` for audit. No tokens or secrets ever appear here — the
  # update is user content, credentials stay in the Secrets Pack.
  @[Chronicle::Packs::Annotations::ObjectType(name: "telegram_update", description: "A raw inbound Telegram update injected by the edge driver (poller/webhook). telegram_ingester translates it into a chat_input, which is where the conversation machinery begins.")]
  struct TelegramUpdate
    include JSON::Serializable

    getter update_id : Int32
    getter chat_id : String
    getter user_id : String
    getter username : String? = nil
    getter text : String = ""
    getter message_id : Int32? = nil
    getter received_at : String? = nil
    getter raw : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @update_id : Int32,
      @chat_id : String,
      @user_id : String,
      @username : String? = nil,
      @text : String = "",
      @message_id : Int32? = nil,
      @received_at : String? = nil,
      @raw : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

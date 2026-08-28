require "json"

module Chronicle::Packs::WhatsApp
  # WhatsApp Adapter Pack object types. Ported from upstream
  # packs/whatsapp/object_types.py. One object type: the raw inbound message,
  # injected at the edge by the webhook receiver (Meta's WhatsApp Cloud API
  # delivers via webhooks; there is no long-poll). Everything conversational
  # happens in the Chat Pack — this pack is a transport adapter, nothing
  # more. Structurally the mirror of the Telegram Adapter Pack.

  # A raw inbound WhatsApp message, as injected by the webhook driver.
  #
  # Only the fields the adapter needs are lifted out; the trimmed original
  # lives in ``raw`` for audit. No tokens or secrets ever appear here.
  @[Chronicle::Packs::Annotations::ObjectType(name: "whatsapp_message", description: "A raw inbound WhatsApp Cloud API message injected by the webhook driver. whatsapp_ingester translates it into a chat_input, which is where the conversation machinery begins.")]
  struct WhatsAppMessage
    include JSON::Serializable

    getter message_id : String
    getter from_number : String
    getter profile_name : String? = nil
    getter text : String = ""
    getter timestamp : String? = nil
    getter received_at : String? = nil
    getter raw : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @message_id : String,
      @from_number : String,
      @profile_name : String? = nil,
      @text : String = "",
      @timestamp : String? = nil,
      @received_at : String? = nil,
      @raw : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

require "json"
require "time"

module Chronicle::Packs::Telegram
  # Telegram Adapter Pack tools. Ported from upstream packs/telegram/tools.py.
  #
  # submit_telegram_update is what edge drivers (the long-poller, a webhook
  # receiver, the demo server's /channels/telegram/update endpoint) call to
  # inject a raw Telegram update into the graph. It normalizes Telegram's
  # update JSON down to the fields the adapter needs; everything after that
  # is reactive.

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Coerce a JSON value to String like Python's str() (telegram ids arrive
  # as numbers; chat_id/user_id are strings on the adapter surface).
  def self._as_string(value : JSON::Any?) : String
    if s = value.try(&.as_s?)
      s
    elsif i = value.try(&.as_i?)
      i.to_s
    else
      ""
    end
  end

  # Normalize a raw Telegram update and add it as a telegram_update object.
  # Accepts the wire shape of the Bot API's getUpdates/webhook payloads
  # ({"update_id": ..., "message": {...}}). Non-message updates (edits,
  # callbacks) return nil.
  def self.submit_telegram_update_fn(
    graph : Chronicle::GraphProjection,
    update : Hash(String, JSON::Any),
    frame_id : String? = nil,
  ) : Chronicle::GraphObject?
    message = update["message"]?.try(&.as_h) || {} of String => JSON::Any
    return nil if message.empty?
    chat = message["chat"]?.try(&.as_h) || {} of String => JSON::Any
    user = message["from"]?.try(&.as_h) || {} of String => JSON::Any

    graph.add_object("telegram_update", TelegramUpdate.new(
      update_id: update["update_id"]?.try(&.as_i?) || 0,
      chat_id: _as_string(chat["id"]?),
      user_id: _as_string(user["id"]?),
      username: user["username"]?.try(&.as_s?),
      text: message["text"]?.try(&.as_s?) || "",
      message_id: message["message_id"]?.try(&.as_i?),
      received_at: _now_iso,
      raw: {
        "date"          => message["date"]? || JSON::Any.new(nil),
        "chat_type"     => chat["type"]? || JSON::Any.new(nil),
        "language_code" => user["language_code"]? || JSON::Any.new(nil),
      },
      frame_id: frame_id,
      metadata: {} of String => JSON::Any,
    ).to_json, actor: "telegram")
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "telegram tools require a bound graph (set Telegram.bound_graph)"
    )
  end

  @[Chronicle::Packs::Annotations::Tool(name: "submit_telegram_update", description: "Inject a raw Telegram Bot API update (getUpdates/webhook wire shape) into the graph as a telegram_update object. The adapter behaviors take it from there.", deterministic: true)]
  def submit_telegram_update_tool(args : String) : String
    input = JSON.parse(args).as_h
    update = input["update"]?.try(&.as_h) || {} of String => JSON::Any
    result = submit_telegram_update_fn(
      bound_graph_or_raise,
      update,
      frame_id: input["frame_id"]?.try(&.as_s?),
    )
    result ? {"id" => JSON::Any.new(result.id)}.to_json : "null"
  end
end

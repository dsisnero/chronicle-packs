require "json"
require "time"

module Chronicle::Packs::WhatsApp
  # WhatsApp Adapter Pack tools. Ported from upstream packs/whatsapp/tools.py.
  #
  # submit_whatsapp_webhook is what the webhook receiver (the demo server's
  # POST /channels/whatsapp/webhook, or any HTTPS endpoint you point Meta at)
  # calls with the Cloud API's webhook envelope. It unwraps
  # entry[].changes[].value.messages[] into whatsapp_message objects;
  # everything after that is reactive.

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Unwrap a Cloud API webhook envelope into whatsapp_message objects. One
  # envelope can carry several messages (and also status updates, which are
  # skipped in v0.1). Returns the created objects.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream webhook entry/change/value/message nesting
  def self.submit_whatsapp_webhook_fn(
    graph : Chronicle::GraphProjection,
    payload : Hash(String, JSON::Any),
    frame_id : String? = nil,
  ) : Array(Chronicle::GraphObject)
    created = [] of Chronicle::GraphObject
    (payload["entry"]?.try(&.as_a) || [] of JSON::Any).each do |entry|
      entry_h = entry.as_h
      (entry_h["changes"]?.try(&.as_a) || [] of JSON::Any).each do |change|
        change_h = change.as_h
        value = change_h["value"]?.try(&.as_h) || {} of String => JSON::Any
        contacts = {} of String => String
        (value["contacts"]?.try(&.as_a) || [] of JSON::Any).each do |contact|
          c = contact.as_h
          wa_id = c["wa_id"]?.try(&.as_s?) || ""
          name = (c["profile"]?.try(&.as_h) || {} of String => JSON::Any)["name"]?.try(&.as_s?)
          contacts[wa_id] = name if name
        end
        (value["messages"]?.try(&.as_a) || [] of JSON::Any).each do |message|
          m = message.as_h
          next unless m["type"]?.try(&.as_s?) == "text" # media/reactions/etc. — v0.1 converses in text
          from_number = m["from"]?.try(&.as_s?) || ""
          created << graph.add_object("whatsapp_message", WhatsAppMessage.new(
            message_id: m["id"]?.try(&.as_s?) || "",
            from_number: from_number,
            profile_name: contacts[from_number]?,
            text: (m["text"]?.try(&.as_h) || {} of String => JSON::Any)["body"]?.try(&.as_s?) || "",
            timestamp: m["timestamp"]?.try(&.as_s?),
            received_at: _now_iso,
            raw: {"type" => m["type"]? || JSON::Any.new(nil)},
            frame_id: frame_id,
            metadata: {} of String => JSON::Any,
          ).to_json, actor: "whatsapp")
        end
      end
    end
    created
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "whatsapp tools require a bound graph (set WhatsApp.bound_graph)"
    )
  end

  @[Chronicle::Packs::Annotations::Tool(name: "submit_whatsapp_webhook", description: "Inject a WhatsApp Cloud API webhook envelope into the graph — each text message becomes a whatsapp_message object. The adapter behaviors take it from there.", deterministic: true)]
  def submit_whatsapp_webhook_tool(args : String) : String
    input = JSON.parse(args).as_h
    payload = input["payload"]?.try(&.as_h) || {} of String => JSON::Any
    created = submit_whatsapp_webhook_fn(
      bound_graph_or_raise,
      payload,
      frame_id: input["frame_id"]?.try(&.as_s?),
    )
    created.map { |obj| {"id" => JSON::Any.new(obj.id)} }.to_json
  end
end

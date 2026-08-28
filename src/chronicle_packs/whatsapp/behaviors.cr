require "json"
require "time"
require "set"

module Chronicle::Packs::WhatsApp
  # WhatsApp Adapter Pack behaviors. Ported from upstream
  # packs/whatsapp/behaviors.py. Two behaviors — the whole adapter,
  # structurally the mirror of the Telegram Adapter Pack (the two differ
  # only in wire shapes and identity refs):
  #
  #   whatsapp_ingester    — whatsapp_message.created → chat_input. The Chat
  #                          Pack owns everything conversational.
  #
  #   whatsapp_dispatcher  — comm_response_candidate.created (channel=whatsapp,
  #                          approved) → capability_call proposal. Outbound
  #                          sends are ordinary gateway capabilities with the
  #                          access token injected at execution time.
  #
  # Identity: user_ref is "whatsapp:<phone>". Bind the owner with
  # IdentitySettings.owner_identifiers (or register_principal) so reply
  # gating recognizes them — a WhatsApp business number is reachable by
  # anyone who has it, which is exactly what the gate is for.
  #
  # Dedup: _SEEN_MESSAGE_IDS guards Meta's at-least-once webhook delivery
  # in-process; replay after restart does not re-fire behaviors.

  # In-process at-least-once guard for Meta's webhook delivery (wamid dedup).
  class_property seen_message_ids = Set(String).new

  # Reset the in-process message dedup guard — call between fixtures.
  def self.clear_seen_messages : Nil
    self.seen_message_ids = Set(String).new
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json, actor: "whatsapp")
  end

  # Translate a WhatsApp message into a chat_input.
  @[Chronicle::Packs::Annotations::Behavior(name: "whatsapp_ingester", on: ["object.created"], where: {"type" => "whatsapp_message"}, creates: ["chat_input"])]
  def whatsapp_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : WhatsAppSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    wa_obj_id = payload["id"]?.try(&.as_s?)
    return if wa_obj_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    wamid = data["message_id"]?.try(&.as_s?) || ""
    if !wamid.empty?
      return if seen_message_ids.includes?(wamid)
      seen_message_ids.add(wamid)
    end

    text = (data["text"]?.try(&.as_s?) || "").strip
    from_number = data["from_number"]?.try(&.as_s?)
    return if text.empty? || from_number.nil? || from_number.empty? # Non-text messages (media, reactions) are recorded but not conversed.

    begin
      chat_input = graph.add_object("chat_input", Chronicle::Packs::Chat::ChatInput.new(
        user_ref: "whatsapp:#{from_number}",
        content: text,
        session_id: nil,
        frame_id: data["frame_id"]?.try(&.as_s?),
        role: "user",
        metadata: {
          "channel"      => JSON::Any.new("whatsapp"),
          "to_number"    => JSON::Any.new(from_number),
          "profile_name" => data["profile_name"]? || JSON::Any.new(nil),
          "wamid"        => JSON::Any.new(wamid),
        },
      ).to_json, actor: "whatsapp.whatsapp_ingester")
      graph.add_relation(wa_obj_id, chat_input.id, "wa_ingested_as", actor: "whatsapp.whatsapp_ingester")
    rescue
    end
  end

  # Deliver an approved whatsapp response via the Tool Gateway.
  @[Chronicle::Packs::Annotations::Behavior(name: "whatsapp_dispatcher", on: ["object.created"], where: {"type" => "comm_response_candidate", "data.channel" => "whatsapp", "data.status" => "approved"}, creates: ["capability_call"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream whatsapp_dispatcher routing branches
  def whatsapp_dispatcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : WhatsAppSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    adapter = meta["adapter"]?.try(&.as_h) || {} of String => JSON::Any
    to_number = adapter["to_number"]?.try(&.as_s?) || meta["to_number"]?.try(&.as_s?)

    # Routing fallback: the candidate's message object carries adapter data.
    if to_number.nil? && (message_id = data["message_id"]?.try(&.as_s?))
      begin
        msg = graph.get_object(message_id)
        if msg
          msg_meta = JSON.parse(msg.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any
          to_number = (msg_meta["adapter"]?.try(&.as_h) || {} of String => JSON::Any)["to_number"]?.try(&.as_s?)
        end
      rescue
      end
    end
    return if to_number.nil? # No routing data — nothing to deliver to.

    content = data["content"]?.try(&.as_s?) || ""
    return if content.empty?

    begin
      call = graph.add_object("capability_call", ToolGateway::CapabilityCall.new(
        provider_id: "",
        provider_name: "whatsapp",
        capability_name: "send_message",
        input_data: {"to" => JSON::Any.new(to_number), "text" => JSON::Any.new(content)},
        credential_ref_name: settings.credential_name,
        risk_class: ToolGateway::RiskClass.parse?(settings.outbound_risk_class) || ToolGateway::RiskClass::Low,
        status: ToolGateway::CallStatus::Proposed,
        proposed_by: "whatsapp_dispatcher",
        frame_id: data["frame_id"]?.try(&.as_s?),
        proposed_at: _now_iso,
        metadata: {"candidate_id" => JSON::Any.new(candidate_id)},
      ).to_json, actor: "whatsapp.whatsapp_dispatcher")
      graph.add_relation(call.id, candidate_id, "delivers", actor: "whatsapp.whatsapp_dispatcher")
      _merge_patch(graph, candidate_id, {"metadata" => JSON::Any.new(meta.merge({"delivery_call_id" => JSON::Any.new(call.id)}))})
    rescue
    end # Tool Gateway not loaded — candidate stays undelivered but recorded.
  end
end

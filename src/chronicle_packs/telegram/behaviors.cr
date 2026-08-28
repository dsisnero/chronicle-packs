require "json"
require "time"
require "set"

module Chronicle::Packs::Telegram
  # Telegram Adapter Pack behaviors. Ported from upstream
  # packs/telegram/behaviors.py. Two behaviors — the whole adapter:
  #
  #   telegram_ingester    — telegram_update.created → chat_input. The Chat
  #                          Pack owns everything conversational (sessions,
  #                          memory, reply gating, the agentic responder);
  #                          this adapter only translates transport.
  #
  #   telegram_dispatcher  — comm_response_candidate.created (channel=telegram,
  #                          approved) → capability_call proposal. Outbound
  #                          sends are ordinary gateway capabilities: recorded,
  #                          policy-checked, executed with the bot token
  #                          injected by the Secrets Pack at execution time.
  #                          The adapter never touches the network or the
  #                          credential itself.
  #
  # Identity: user_ref is "telegram:<user_id>". Bind the owner via
  # IdentitySettings.owner_identifiers (or register_principal) so reply
  # gating recognizes them.
  #
  # Dedup: _SEEN_UPDATE_IDS is an in-process at-least-once guard for twitchy
  # pollers. Replay after a restart does not re-fire behaviors, so persisted
  # updates are never double-ingested; clear_seen_updates() between fixtures.

  # In-process at-least-once guard for twitchy pollers (update_id dedup).
  class_property seen_update_ids = Set(Int32).new

  # Reset the in-process update dedup guard — call between fixtures.
  def self.clear_seen_updates : Nil
    self.seen_update_ids = Set(Int32).new
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
    graph.patch_object(target, data.to_json, actor: "telegram")
  end

  # Translate a Telegram update into a chat_input.
  @[Chronicle::Packs::Annotations::Behavior(name: "telegram_ingester", on: ["object.created"], where: {"type" => "telegram_update"}, creates: ["chat_input"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream telegram_ingester dedup/text branches
  def telegram_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TelegramSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    update_id = payload["id"]?.try(&.as_s?)
    return if update_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    tg_update_id = data["update_id"]?.try(&.as_i?)
    if tg_update_id.nil?
      # Non-message updates carry no update id; nothing to dedup against.
    elsif seen_update_ids.includes?(tg_update_id)
      return
    else
      seen_update_ids.add(tg_update_id)
    end

    text = (data["text"]?.try(&.as_s?) || "").strip
    user_id = data["user_id"]?.try(&.as_s?)
    return if text.empty? || user_id.nil? || user_id.empty? # Non-text updates (stickers, joins) are recorded but not conversed.

    begin
      chat_input = graph.add_object("chat_input", Chronicle::Packs::Chat::ChatInput.new(
        user_ref: "telegram:#{user_id}",
        content: text,
        session_id: nil,
        frame_id: data["frame_id"]?.try(&.as_s?),
        role: "user",
        metadata: {
          "channel"             => JSON::Any.new("telegram"),
          "chat_id"             => data["chat_id"]? || JSON::Any.new(nil),
          "username"            => data["username"]? || JSON::Any.new(nil),
          "telegram_message_id" => data["message_id"]? || JSON::Any.new(nil),
        },
      ).to_json, actor: "telegram.telegram_ingester")
      graph.add_relation(update_id, chat_input.id, "ingested_as", actor: "telegram.telegram_ingester")
    rescue
    end
  end

  # Deliver an approved telegram response via the Tool Gateway.
  @[Chronicle::Packs::Annotations::Behavior(name: "telegram_dispatcher", on: ["object.created"], where: {"type" => "comm_response_candidate", "data.channel" => "telegram", "data.status" => "approved"}, creates: ["capability_call"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream telegram_dispatcher routing branches
  def telegram_dispatcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TelegramSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    adapter = meta["adapter"]?.try(&.as_h) || {} of String => JSON::Any
    chat_id = adapter["chat_id"]?.try(&.as_s?) || meta["chat_id"]?.try(&.as_s?)

    # Routing fallback: the candidate's message object carries adapter data.
    if chat_id.nil? && (message_id = data["message_id"]?.try(&.as_s?))
      begin
        msg = graph.get_object(message_id)
        if msg
          msg_meta = JSON.parse(msg.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any
          chat_id = (msg_meta["adapter"]?.try(&.as_h) || {} of String => JSON::Any)["chat_id"]?.try(&.as_s?)
        end
      rescue
      end
    end
    return if chat_id.nil? # No routing data — nothing to deliver to.

    content = data["content"]?.try(&.as_s?) || ""
    return if content.empty?

    begin
      call = graph.add_object("capability_call", ToolGateway::CapabilityCall.new(
        provider_id: "",
        provider_name: "telegram",
        capability_name: "send_message",
        input_data: {"chat_id" => JSON::Any.new(chat_id), "text" => JSON::Any.new(content)},
        credential_ref_name: settings.credential_name,
        risk_class: ToolGateway::RiskClass.parse?(settings.outbound_risk_class) || ToolGateway::RiskClass::Low,
        status: ToolGateway::CallStatus::Proposed,
        proposed_by: "telegram_dispatcher",
        frame_id: data["frame_id"]?.try(&.as_s?),
        proposed_at: _now_iso,
        metadata: {"candidate_id" => JSON::Any.new(candidate_id)},
      ).to_json, actor: "telegram.telegram_dispatcher")
      graph.add_relation(call.id, candidate_id, "delivers", actor: "telegram.telegram_dispatcher")
      _merge_patch(graph, candidate_id, {"metadata" => JSON::Any.new(meta.merge({"delivery_call_id" => JSON::Any.new(call.id)}))})
    rescue
    end # Tool Gateway not loaded — candidate stays undelivered but recorded.
  end
end

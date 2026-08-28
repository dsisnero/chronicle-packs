require "json"
require "time"

module Chronicle::Packs::Communication
  # Communication behaviors — the four-part comm_* action layer. Ported from
  # upstream packs/communication/behaviors.py. All deterministic (heuristic
  # intent detection, no LLM required).

  # Modular-state thread registry ("channel::thread_key" -> comm_thread_id)
  # and message counts. Call clear_thread_registry between test fixtures.
  class_property thread_registry = {} of String => String
  class_property thread_message_count = {} of String => Int32

  def self.clear_thread_registry : Nil
    self.thread_registry = {} of String => String
    self.thread_message_count = {} of String => Int32
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  def self._thread_key(channel : String, thread_id_hint : String?) : String
    "#{channel}::#{thread_id_hint || "__root__"}"
  end

  # Intent keyword/pattern rules and tie-break priorities (faithful to
  # upstream _INTENT_PATTERNS / _INTENT_PRIORITY). Nested so the DSL pack
  # macro doesn't treat these as typed constants.
  module Intents
    PATTERNS = {
      "query"            => ["?", "what is", "what are", "how do", "how does", "how can", "why is", "who is", "where is", "when is", "tell me", "explain", "can you tell", "what's", "how's", "do you know", "could you explain"],
      "request"          => ["please", "can you", "could you", "would you", "draft", "write", "create", "generate", "make", "build", "send", "schedule", "set up", "prepare", "summarize", "review and", "help me", "i need", "we need", "i'd like", "i would like"],
      "reply"            => ["in reply to", "as discussed", "following up", "per our", "as mentioned", "as i said", "re:", "thanks for", "thank you for", "appreciated", "got it", "understood", "noted", "sounds good", "agreed"],
      "notification"     => ["fyi", "for your information", "just to let you know", "heads up", "update:", "status update", "letting you know", "wanted to inform", "just wanted to share", "quick note"],
      "approval_request" => ["approve", "approval", "permission", "authorize", "lgtm", "sign off", "sign-off", "okay to proceed", "can i proceed", "is it okay", "do i have permission", "requesting approval", "need your approval", "requires approval", "pending approval", "waiting for approval", "please approve", "require your sign", "your authorization", "your authorisation"],
      "review"           => ["review", "take a look", "feedback", "thoughts on", "what do you think", "check this", "look over", "look at", "opinion on", "evaluate", "assess", "critique"],
    } of String => Array(String)

    PRIORITY = {
      "approval_request" => 6,
      "review"           => 5,
      "notification"     => 4,
      "reply"            => 3,
      "request"          => 2,
      "query"            => 1,
      "unknown"          => 0,
    } of String => Int32
  end

  # Sentinel warnings are returned as (intent, confidence, reasoning).
  alias IntentVerdict = Tuple(String, Float64, String)

  # Classify intent using keyword heuristics. Returns {intent, confidence,
  # reasoning}. More specific intents win ties.
  def self._classify_intent(content : String, intent_hint : String?) : IntentVerdict
    if intent_hint && Intents::PATTERNS.has_key?(intent_hint)
      return {intent_hint, 0.9, "provided via intent_hint"}
    end

    content_lower = content.downcase
    scores = {} of String => Int32
    Intents::PATTERNS.each do |intent, patterns|
      hits = patterns.count { |pattern| content_lower.includes?(pattern) }
      scores[intent] = hits if hits > 0
    end

    if scores.empty?
      return {"unknown", 0.4, "no intent signals found in content"}
    end

    best = scores.max_by { |intent, score| {score, Intents::PRIORITY.fetch(intent, 0)} }[0]
    confidence = Math.min(0.55 + (scores[best].to_f * 0.12), 0.93)

    runners = scores.to_a.sort_by { |intent, score| {-score, -Intents::PRIORITY.fetch(intent, 0)} }
    secondary = runners.size >= 2 ? runners[1][0] : nil
    reasoning = "matched #{scores[best]} signal(s) for '#{best}'"
    reasoning += "; secondary: '#{secondary}'" if secondary
    {best, confidence, reasoning}
  end

  # Classify inbound CommMessage intent into a CommIntent graph object.
  @[Chronicle::Packs::Annotations::Behavior(name: "intent_detector", on: ["object.created"], where: {"type" => "comm_message"}, creates: ["comm_intent"])]
  def intent_detector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?
    msg_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return if msg_data["direction"]?.try(&.as_s?) != "inbound"

    content = msg_data["content"]?.try(&.as_s) || ""
    intent_hint = msg_data["intent_hint"]?.try(&.as_s?)
    threshold = settings.low_confidence_intent_threshold

    intent, confidence, reasoning = _classify_intent(content, intent_hint)
    if confidence < threshold
      intent = "unknown"
      reasoning = "confidence #{confidence} below threshold #{threshold}"
    end

    begin
      comm_intent = CommIntent.new(
        message_id: msg_id,
        thread_id: msg_data["thread_id"]?.try(&.as_s?),
        intent: IntentKind.parse?(intent) || IntentKind::Unknown,
        confidence: confidence,
        reasoning: reasoning,
        detected_by: "intent_detector",
        frame_id: msg_data["frame_id"]?.try(&.as_s?),
      )
      obj = graph.add_object("comm_intent", comm_intent.to_json, actor: "intent_detector")
      graph.add_relation(obj.id, msg_id, "intent_of", actor: "intent_detector")
    rescue
      # never raised in-process; keep the upstream swallow
    end
  end

  # Route actionable intents into the tool gateway as capability proposals.
  @[Chronicle::Packs::Annotations::Behavior(name: "intent_router", on: ["object.created"], where: {"type" => "comm_intent"}, creates: ["capability_call"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _route_intent routing branches
  def intent_router(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    routes = settings.intent_routes
    return if routes.empty?

    payload = JSON.parse(event.payload).as_h
    intent_id = payload["id"]?.try(&.as_s?)
    return if intent_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    intent_kind = data["intent"]?.try(&.as_s?)
    route = intent_kind && routes[intent_kind]?
    return if route.nil?
    return if (data["confidence"]?.try(&.as_f?) || 0.0) < settings.intent_route_min_confidence

    message_id = data["message_id"]?.try(&.as_s?)
    msg = message_id ? (begin
      graph.get_object(message_id)
    rescue
      nil
    end) : nil
    content = msg ? (JSON.parse(msg.data)["content"]?.try(&.as_s?) || "") : ""

    content_field = route["content_field"]?.try(&.as_s?) || "text"
    input_data = (route["input"]?.try(&.as_h) || {} of String => JSON::Any).dup
    input_data[content_field] = JSON::Any.new(content)

    begin
      call_payload = {
        "provider_id"         => JSON::Any.new(route["provider_id"]?.try(&.as_s?) || ""),
        "provider_name"       => JSON::Any.new(route["provider_name"]?.try(&.as_s?) || ""),
        "capability_name"     => JSON::Any.new(route["capability_name"]?.try(&.as_s?) || ""),
        "input_data"          => JSON::Any.new(input_data),
        "credential_ref_name" => (route["credential_ref_name"]?.try(&.as_s?)).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
        "risk_class"          => JSON::Any.new(route["risk_class"]?.try(&.as_s?) || "medium"),
        "status"              => JSON::Any.new("proposed"),
        "proposed_by"         => JSON::Any.new("intent_router"),
        "frame_id"            => (data["frame_id"]?.try(&.as_s?)).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
        "proposed_at"         => JSON::Any.new(_now_iso),
        "metadata"            => JSON::Any.new({"intent_id" => JSON::Any.new(intent_id), "intent" => JSON::Any.new(intent_kind)}),
      } of String => JSON::Any
      call = graph.add_object("capability_call", call_payload.to_json, actor: "intent_router")
      graph.add_relation(call.id, intent_id, "fulfills_intent", actor: "intent_router")
    rescue
      # Tool Gateway not loaded — intents stay informational.
    end
  end

  # Create or update CommThread for incoming messages.
  @[Chronicle::Packs::Annotations::Behavior(name: "thread_tracker", on: ["object.created"], where: {"type" => "comm_message"}, creates: ["comm_thread", "comm_participant"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream thread_tracker merge/create branches
  def thread_tracker(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?
    msg_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    channel = msg_data["channel"]?.try(&.as_s?) || settings.default_channel
    now = _now_iso
    meta = msg_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    thread_id_hint = msg_data["thread_id"]?.try(&.as_s?) || meta["thread_id_hint"]?.try(&.as_s?)
    key = _thread_key(channel, thread_id_hint)
    sender_ref = msg_data["sender_ref"]?.try(&.as_s?) || ""

    thread_id = thread_registry[key]?
    if thread_id
      thread_message_count[thread_id] = (thread_message_count[thread_id]? || 0) + 1
      begin
        _merge_patch(graph, thread_id, {"last_message_at" => JSON::Any.new(now), "message_count" => JSON::Any.new(thread_message_count[thread_id])})
      rescue
      end
      unless msg_data["thread_id"]?
        begin
          _merge_patch(graph, msg_id, {"thread_id" => JSON::Any.new(thread_id)})
        rescue
        end
      end
    elsif settings.auto_create_threads?
      begin
        thread = CommThread.new(
          channel: channel,
          subject: meta["subject"]?.try(&.as_s?),
          status: ThreadStatus::Open,
          created_at: now,
          last_message_at: now,
          message_count: 1,
          frame_id: msg_data["frame_id"]?.try(&.as_s?),
        )
        thread_obj = graph.add_object("comm_thread", thread.to_json, actor: "thread_tracker")
        thread_id = thread_obj.id
        thread_registry[key] = thread_id
        thread_message_count[thread_id] = 1
        begin
          _merge_patch(graph, msg_id, {"thread_id" => JSON::Any.new(thread_id)})
        rescue
        end
      rescue
        return
      end
    else
      return
    end

    begin
      graph.add_relation(thread_id, msg_id, "thread_contains", actor: "thread_tracker")
    rescue
    end

    unless sender_ref.empty?
      begin
        role = msg_data["direction"]?.try(&.as_s?) == "inbound" ? ParticipantRole::Sender : ParticipantRole::Recipient
        participant = CommParticipant.new(
          thread_id: thread_id,
          principal_ref: sender_ref,
          role: role,
          joined_at: now,
          frame_id: msg_data["frame_id"]?.try(&.as_s?),
        )
        graph.add_object("comm_participant", participant.to_json, actor: "thread_tracker")
      rescue
      end
    end
  end

  # Dispatch approved CommResponseCandidates to channel adapters.
  @[Chronicle::Packs::Annotations::Behavior(name: "response_dispatcher", on: ["object.created"], where: {"type" => "comm_response_candidate"}, creates: ["comm_response_candidate"])]
  def response_dispatcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    return unless settings.auto_dispatch_approved_responses?

    payload = JSON.parse(event.payload).as_h
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "approved"

    thread_id = data["thread_id"]?.try(&.as_s?)
    if thread_id
      begin
        graph.add_relation(candidate_id, thread_id, "dispatched_to", actor: "response_dispatcher")
      rescue
      end
    end

    begin
      _merge_patch(graph, candidate_id, {"status" => JSON::Any.new("sent")})
    rescue
    end
  end

  # Merge a patch onto an object (chronicle's patch_object replaces data;
  # upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json)
  end
end

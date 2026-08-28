require "json"
require "time"

module Chronicle::Packs::Chat
  # Chat Adapter Pack behaviors. Ported from upstream packs/chat/behaviors.py.
  #
  # The chat adapter translates interactive chat input into channel-neutral
  # CommMessage objects and delivers assistant responses back to the chat
  # interface. Channel adapters (messenger/telegram/whatsapp) emit chat_input
  # with metadata.channel set; the channel rides on the comm_message so
  # outbound delivery routes correctly, and adapter routing data (chat ids,
  # phone numbers) travels under metadata.adapter.
  #
  # Conversation memory is graph-native: chat_context_assembler reconstructs
  # prior turns from persisted chat_turn objects (linked to the session via
  # session_contains_turn), so context survives an API-server restart and
  # needs no in-process history. The in-process maps below are convenience
  # caches only — every value they hold is also derivable from the graph, and
  # the behaviors fall back to graph lookups on a cache miss.

  # user_ref → {"session_id", "turn_count"} — resume-by-user shortcut.
  class_property session_registry = {} of String => Hash(String, JSON::Any)
  # comm_message_id → chat_turn_id — delivery plumbing for chat_responder.
  class_property message_to_turn = {} of String => String
  # comm_message_id → session_id — delivery plumbing.
  class_property message_to_session = {} of String => String

  # Reset the in-process caches — call between test fixtures (and a useful
  # way to simulate an API-server restart, since the graph is the real store).
  def self.clear_session_registry : Nil
    self.session_registry = {} of String => Hash(String, JSON::Any)
    self.message_to_turn = {} of String => String
    self.message_to_session = {} of String => String
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # ── chat_ingester ─────────────────────────────────────────────────────────

  # Translate ChatInput into CommMessage + ChatSession + ChatTurn.
  #
  # On: object.created (chat_input)
  # Creates: source(kind=chat_message), comm_message(channel=chat, inbound),
  #          chat_session (or resumes), chat_turn
  # Relations: derived_from_source, session_contains_turn, turn_from_input
  #
  # Session continuity: resumes existing session by user_ref (or explicit
  # session_id). Thread continuity: uses session_id as thread_id_hint so
  # thread_tracker creates a per-session comm_thread (key="chat::<session_id>")
  # rather than a shared root. CommThread is created downstream by
  # thread_tracker (Communication Pack).
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_ingester", on: ["object.created"], where: {"type" => "chat_input"}, creates: ["source", "comm_message", "chat_session", "chat_turn"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream chat_ingester session-resolve branches
  def chat_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    input_id = payload["id"]?.try(&.as_s?)
    return if input_id.nil?
    inp = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    user_ref = inp["user_ref"]?.try(&.as_s?) || "unknown_user"
    content = inp["content"]?.try(&.as_s?) || ""
    given_session_id = inp["session_id"]?.try(&.as_s?)
    frame_id = inp["frame_id"]?.try(&.as_s?)
    now = _now_iso

    # ── Channel resolution ────────────────────────────────────────────────
    # chat_input is the entry point for EVERY interactive conversation. The
    # channel rides on the comm_message; adapter routing data travels under
    # metadata.adapter.
    input_meta = (inp["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
    channel = input_meta.delete("channel").try(&.as_s?) || "chat"

    # ── 1. Resolve or create ChatSession (graph-first, restart-safe) ──────
    session_key = user_ref
    session_id : String? = nil
    turn_count = 1

    if given_session_id
      sess = begin
        graph.get_object(given_session_id)
      rescue
        nil
      end
      if sess
        session_id = given_session_id
        sess_data = JSON.parse(sess.data).as_h
        turn_count = (sess_data["turn_count"]?.try(&.as_i?) || 0) + 1
      end
    end

    if session_id.nil? && (reg = session_registry[session_key]?)
      session_id = reg["session_id"]?.try(&.as_s?)
      turn_count = (reg["turn_count"]?.try(&.as_i?) || 0) + 1
    end

    if session_id.nil?
      begin
        session_obj = graph.add_object("chat_session", {"user_ref" => JSON::Any.new(user_ref), "started_at" => JSON::Any.new(now), "status" => JSON::Any.new("active"), "turn_count" => JSON::Any.new(0), "llm_config" => JSON::Any.new({} of String => JSON::Any), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id))}.to_json, actor: "chat_ingester")
        session_id = session_obj.id
      rescue
        return
      end
      turn_count = 1
    end

    # thread_id_hint = session_id ensures each session maps to its own
    # comm_thread (keyed "chat::<session_id>" by thread_tracker).
    thread_id_hint = session_id

    # ── Reply gate: identity on the respond path ──────────────────────────
    # Decided HERE (at ingestion) and stamped onto the comm_message, because
    # chat_llm_responder matches the verdict declaratively in its `where`
    # clause — that is what lets a gated sender skip the (paid) LLM call
    # entirely. Fail-closed under restrictive policies; blocked senders are
    # deflected even under "open".
    gate = begin
      Chronicle::Packs::Communication.decide_reply(graph, user_ref, reply_policy: settings.reply_policy)
    rescue
      {"gate" => JSON::Any.new("open"), "role" => JSON::Any.new(nil), "reason" => JSON::Any.new("gating unavailable")} of String => JSON::Any
    end

    # ── 2. Create Core Source ──────────────────────────────────────────────
    source_id = begin
      source = graph.add_object("source", {"kind" => JSON::Any.new("chat_message"), "content" => JSON::Any.new(content), "channel" => JSON::Any.new(channel), "sender_ref" => JSON::Any.new(user_ref), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id)), "metadata" => JSON::Any.new({"session_id" => JSON::Any.new(session_id), "turn_number" => JSON::Any.new(turn_count)} of String => JSON::Any)}.to_json, actor: "chat_ingester")
      source.id
    rescue
      return
    end

    # ── 3. Create CommMessage ──────────────────────────────────────────────
    comm_msg_id = begin
      comm_msg = graph.add_object("comm_message", {"channel" => JSON::Any.new(channel), "sender_ref" => JSON::Any.new(user_ref), "content" => JSON::Any.new(content), "direction" => JSON::Any.new("inbound"), "source_id" => JSON::Any.new(source_id), "thread_id" => JSON::Any.new(nil), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id)), "metadata" => JSON::Any.new({"thread_id_hint" => JSON::Any.new(thread_id_hint), "session_id" => JSON::Any.new(session_id), "conversational" => JSON::Any.new(true), "reply_gate" => JSON::Any.new(gate["gate"]?.try(&.as_s?) || "open"), "reply_gate_reason" => JSON::Any.new(gate["reason"]?.try(&.as_s?) || ""), "sender_role" => JSON::Any.new(gate["role"]?.try(&.as_s?)), "adapter" => JSON::Any.new(input_meta)} of String => JSON::Any)}.to_json, actor: "chat_ingester")
      comm_msg.id
    rescue
      return
    end

    begin
      graph.add_relation(comm_msg_id, source_id, "derived_from_source", actor: "chat_ingester")
    rescue
    end

    # ── 4. Create ChatTurn ─────────────────────────────────────────────────
    turn_id = begin
      turn = graph.add_object("chat_turn", {"session_id" => JSON::Any.new(session_id), "user_message" => JSON::Any.new(content), "assistant_message" => JSON::Any.new(nil), "turn_number" => JSON::Any.new(turn_count), "comm_message_id" => JSON::Any.new(comm_msg_id), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id))}.to_json, actor: "chat_ingester")
      turn.id
    rescue
      return
    end

    begin
      graph.add_relation(session_id, turn_id, "session_contains_turn", actor: "chat_ingester")
    rescue
    end
    begin
      graph.add_relation(turn_id, input_id, "turn_from_input", actor: "chat_ingester")
    rescue
    end

    # ── 5. Update session turn count + registries ──────────────────────────
    begin
      _merge_patch(graph, session_id, {"turn_count" => JSON::Any.new(turn_count)})
    rescue
    end

    # Refresh the convenience caches (hot-path shortcuts, not the source of
    # truth — every value here is also recorded on the graph objects above).
    message_to_turn[comm_msg_id] = turn_id
    message_to_session[comm_msg_id] = session_id
    session_registry[session_key] = {"session_id" => JSON::Any.new(session_id), "turn_count" => JSON::Any.new(turn_count)} of String => JSON::Any

    nil
  end

  # ── chat_context_assembler ────────────────────────────────────────────────

  # Assemble graph-native conversation memory for an inbound chat message.
  #
  # On: object.created (comm_message, channel=chat, direction=inbound)
  # Creates: chat_context (the prior conversation, bounded + formatted)
  # Relations: provides_context_for (chat_context → comm_message)
  #
  # Reads prior ChatTurns for the session from the graph view, formats the
  # most recent max_context_messages of them into a transcript, and links the
  # result to the inbound message so chat_llm_responder's depth-1 view picks
  # it up. Skips silently on the first turn (no prior memory yet).
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_context_assembler", on: ["object.created"], where: {"type" => "comm_message", "data.channel" => "chat", "data.direction" => "inbound"}, creates: ["chat_context"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream chat_context_assembler turn-filter branches
  def chat_context_assembler(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?
    msg_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    meta = msg_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    return if meta["reply_gate"]?.try(&.as_s?) == "deflect" # Gated sender: template reply only — no context assembly.
    session_id = meta["session_id"]?.try(&.as_s?)
    frame_id = msg_data["frame_id"]?.try(&.as_s?)
    return if session_id.nil?

    # Prior turns come from the graph view (restart-safe), not a process dict.
    turns = graph.objects(type: "chat_turn").select { |obj| JSON.parse(obj.data)["session_id"]?.try(&.as_s?) == session_id }
    # Exclude the current, still-unanswered turn — it is the triggering event.
    prior = turns.select { |turn| JSON.parse(turn.data)["comm_message_id"]?.try(&.as_s?) != msg_id }
    return if prior.empty?

    prior.sort_by! { |turn| JSON.parse(turn.data)["turn_number"]?.try(&.as_i?) || 0 }
    # Bound memory to the most recent N turns (0/negative → unbounded).
    limit = settings.max_context_messages
    prior = prior.last(limit) if limit > 0 && prior.size > limit
    return if prior.empty?

    lines = ["Conversation so far (most recent #{prior.size} turn(s)):"]
    prior.each do |turn|
      d = JSON.parse(turn.data).as_h
      n = d["turn_number"]?.try(&.as_i?) || "?"
      user = (d["user_message"]?.try(&.as_s?) || "").strip
      assistant = (d["assistant_message"]?.try(&.as_s?) || "").strip
      lines << "[#{n}] User: #{user}"
      lines << "    Assistant: #{assistant}" unless assistant.empty?
    end
    transcript = lines.join("\n")

    begin
      context = graph.add_object("chat_context", {"session_id" => JSON::Any.new(session_id), "message_id" => JSON::Any.new(msg_id), "turn_count" => JSON::Any.new(prior.size), "transcript" => JSON::Any.new(transcript), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id))}.to_json, actor: "chat_context_assembler")
      # Link to the inbound message so the responder's depth-1 view captures
      # this context without having to widen its own scope.
      graph.add_relation(context.id, msg_id, "provides_context_for", actor: "chat_context_assembler")
    rescue
    end

    nil
  end

  # ── chat_profile_context ──────────────────────────────────────────────────

  # Fold the assistant's self-knowledge into the LLM context for a chat turn.
  #
  # On: object.created (comm_message, channel=chat, direction=inbound)
  # Creates: profile_context_view (the assistant's identity/mission/etc.)
  # Relations: provides_context_for (profile_context_view → comm_message)
  #
  # Agent Profile is an OPTIONAL composition partner; without it, this
  # behavior no-ops and chat runs identity-free. Precedence (two independent
  # knobs): a system_prompt_override is an intentional, specific instruction
  # and always wins; else include_profile gates the profile-assembly path.
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_profile_context", on: ["object.created"], where: {"type" => "comm_message", "data.channel" => "chat", "data.direction" => "inbound"}, creates: ["profile_context_view"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream chat_profile_context override/profile branches
  def chat_profile_context(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?
    msg_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    frame_id = msg_data["frame_id"]?.try(&.as_s?)
    meta = msg_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    return if meta["reply_gate"]?.try(&.as_s?) == "deflect"

    # ── Escape hatch: literal system-prompt override (bypasses the profile) ──
    # Checked BEFORE the include_profile gate: an explicitly configured
    # override is an intentional, specific instruction and is always honored.
    override = settings.system_prompt_override
    if override
      begin
        view = graph.add_object("profile_context_view", {"profile_id" => JSON::Any.new(""), "channel" => JSON::Any.new("chat"), "audience_role" => JSON::Any.new("owner"), "agent_name" => JSON::Any.new(""), "mission" => JSON::Any.new(""), "personality" => JSON::Any.new({} of String => JSON::Any), "active_goals" => JSON::Any.new([] of JSON::Any), "standing_instructions" => JSON::Any.new([JSON::Any.new(override)]), "owner_preferences" => JSON::Any.new({} of String => JSON::Any), "request_id" => JSON::Any.new(nil), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id)), "metadata" => JSON::Any.new({"origin" => JSON::Any.new("system_prompt_override")} of String => JSON::Any)}.to_json, actor: "chat_profile_context")
        graph.add_relation(view.id, msg_id, "provides_context_for", actor: "chat_profile_context")
      rescue
      end
      return
    end

    # No override → the profile path is gated by include_profile.
    return unless settings.include_profile?

    # ── Reuse Agent Profile's assembly (guarded — optional dependency) ───────
    # Audience-aware: the profile view is shaped by WHO is asking. The
    # sender's role was resolved at ingestion and stamped on the message;
    # unresolved senders assemble as "unknown" — the external-shaped view.
    audience_role = meta["sender_role"]?.try(&.as_s?) || "unknown"
    view_model = begin
      Chronicle::Packs::AgentProfile.assemble_profile_view(graph, settings: nil, channel: "chat", audience_role: audience_role, frame_id: frame_id)
    rescue
      nil
    end
    return if view_model.nil?

    begin
      view = graph.add_object("profile_context_view", view_model.to_json, actor: "chat_profile_context")
      graph.add_relation(view.id, msg_id, "provides_context_for", actor: "chat_profile_context")
    rescue
    end

    nil
  end

  # ── Long-term memory ──────────────────────────────────────────────────────
  # Two behaviors connect chat to the Memory Gateway lifecycle so the
  # assistant both BUILDS durable memory and USES it across sessions:
  #   chat_memory_proposer (WRITE) — chat turn → memory_candidate.
  #   chat_memory_context   (READ)  — recall per-message memories.
  # Both are unopinionated and pluggable (see ChatSettings.memory_*).

  # Conversation-tuned cues for the default heuristic write path. Each maps a
  # small set of first-person/durable phrasings to a memory category. This is
  # deliberately tiny and explainable — NOT exhaustive NLP. Nested so the DSL
  # pack macro doesn't treat the tuples as typed constants.
  module MemoryCues
    CHAT_MEMORY_CUES = [
      {"preference", ["i prefer", "i'd prefer", "i would prefer", "i like", "i love", "i hate", "i dislike", "i enjoy", "my favorite", "my favourite", "i'd rather", "i would rather"]},
      {"instruction", ["always", "never", "please make sure", "make sure", "remember to", "remember that", "from now on", "call me", "don't ", "do not "]},
      {"decision", ["we decided", "i decided", "let's go with", "we'll use", "i'll use", "we are going with", "i'm going with", "going forward we"]},
      {"fact", ["my name is", "i am ", "i'm ", "my email", "my timezone", "i live in", "i work", "i'm based in"]},
    ]

    INTERROGATIVE_STARTS = ["what", "who", "whom", "whose", "where", "when", "why", "how", "which", "can ", "could ", "do ", "does ", "did ", "is ", "are ", "was ", "were ", "will ", "would ", "should ", "shall ", "have ", "has "]
  end

  # A question is not a memory candidate. Catches both punctuated
  # ("What's my favorite color?") and bare ("what's my favorite color")
  # interrogatives — the cue matcher would otherwise see "my favorite" and
  # memorize the QUESTION as a preference.
  def self._is_question(text : String) : Bool
    stripped = text.strip.downcase
    stripped.ends_with?("?") || MemoryCues::INTERROGATIVE_STARTS.any? { |cue| stripped.starts_with?(cue) }
  end

  # Return a memory category for *text* if it states something durable, else
  # nil. Small, ordered keyword heuristic — see MemoryCues. Questions never
  # classify (see _is_question).
  def self._classify_chat_memory(text : String) : String?
    return nil if _is_question(text)
    low = text.downcase
    MemoryCues::CHAT_MEMORY_CUES.each do |category, cues|
      return category if cues.any? { |cue| low.includes?(cue) }
    end
    nil
  end

  # Default heuristic WRITE path: chat message → memory_candidate.
  #
  # On: object.created (comm_message, channel=chat, direction=inbound)
  # Creates: memory_candidate (when the message states a durable preference/
  #          instruction/decision/fact)
  #
  # The contract between "noticing something worth remembering" and "the
  # memory lifecycle" is the memory_candidate object — Memory Gateway's
  # candidate_evaluator → memory_writer pick up ANY memory_candidate, no
  # matter who created it. Set memory_write_path="off" to silence this
  # default and avoid double-proposing.
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_memory_proposer", on: ["object.created"], where: {"type" => "comm_message", "data.channel" => "chat", "data.direction" => "inbound"}, creates: ["memory_candidate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream chat_memory_proposer gate branches
  def chat_memory_proposer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    return if settings.memory_write_path != "heuristic"

    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    return if meta["reply_gate"]?.try(&.as_s?) == "deflect" # Don't memorize senders the assistant won't converse with.
    content = (data["content"]?.try(&.as_s?) || "").strip
    frame_id = data["frame_id"]?.try(&.as_s?)
    return if msg_id.nil? || content.size < 6

    category = _classify_chat_memory(content)
    return if category.nil?

    source_id = data["source_id"]?.try(&.as_s?)
    begin
      graph.add_object("memory_candidate", {"text" => JSON::Any.new(content), "confidence" => JSON::Any.new(0.8), "source_ids" => JSON::Any.new(source_id.nil? ? [] of JSON::Any : [JSON::Any.new(source_id)]), "observation_ids" => JSON::Any.new([] of JSON::Any), "category" => JSON::Any.new(category), "subject_ref" => JSON::Any.new(data["sender_ref"]?.try(&.as_s?) || ""), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id))}.to_json, actor: "chat_memory_proposer")
    rescue
    end

    nil
  end

  # READ path: recall durable memory and fold it into this turn's prompt.
  #
  # On: object.created (comm_message, channel=chat, direction=inbound)
  # Creates: memory_context (the recalled memories, as prompt-ready text)
  # Relations: provides_context_for (memory_context → comm_message)
  #
  # This is the half that makes memory *useful*: it queries the Memory
  # Gateway backend for memories relevant to the inbound message and attaches
  # the top matches to the message via provides_context_for, so
  # chat_llm_responder's depth-1 view serializes them straight into the
  # prompt. Memory Gateway is an OPTIONAL partner — guarded so chat still
  # runs without it (recall simply no-ops).
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_memory_context", on: ["object.created"], where: {"type" => "comm_message", "data.channel" => "chat", "data.direction" => "inbound"}, creates: ["memory_context"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream chat_memory_context recall branches
  def chat_memory_context(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    return unless settings.include_memory?

    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    return if meta["reply_gate"]?.try(&.as_s?) == "deflect" # Gated sender: no LLM call happens, so no recall needed.
    query = (data["content"]?.try(&.as_s?) || "").strip
    frame_id = data["frame_id"]?.try(&.as_s?)
    return if msg_id.nil? || query.empty?

    # Access control: by default recall is scoped to the message SENDER, so
    # one user never receives another user's stored memories.
    sender_ref = data["sender_ref"]?.try(&.as_s?)
    results = begin
      Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, query,
        top_k: settings.memory_top_k,
        min_score: settings.memory_min_score,
        behavior_name: "chat_memory_context",
        frame_id: frame_id,
        subject_ref: sender_ref,
        subject_scoped: settings.memory_subject_scoped?,
        include_global: settings.memory_include_global?,
        # Never recall a memory born in the frame that is asking.
        exclude_frame_id: frame_id,
      )
    rescue
      return
    end
    return if results.empty?

    lines = [] of String
    results.each do |res|
      cat = res["category"]?.try(&.as_s?)
      prefix = cat.nil? ? "" : "[#{cat}] "
      lines << "- #{prefix}#{res["text"]?.try(&.as_s?) || ""}"
    end
    summary = "Relevant things you remember about the user:\n" + lines.join("\n")

    begin
      view = graph.add_object("memory_context", {"message_id" => JSON::Any.new(msg_id), "query" => JSON::Any.new(query), "item_count" => JSON::Any.new(results.size), "item_ids" => JSON::Any.new(results.map { |res| JSON::Any.new(res["item_id"]?.try(&.as_s?) || "") }), "summary" => JSON::Any.new(summary), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id)), "metadata" => JSON::Any.new({} of String => JSON::Any)}.to_json, actor: "chat_memory_context")
      graph.add_relation(view.id, msg_id, "provides_context_for", actor: "chat_memory_context")
    rescue
    end

    nil
  end

  # ── chat_llm_responder ────────────────────────────────────────────────────

  # The @llm_behavior's static system prompt (upstream _RESPONDER_DESCRIPTION).
  # Nested so the DSL pack macro doesn't treat the String as a typed constant.
  module ResponderPrompt
    DESCRIPTION = "You are the assistant in an ActiveGraph-powered chat. Read the user's most recent message (the triggering comm_message) together with any prior context in the graph view, then reply helpfully and concisely."
  end

  # Produce a CommResponseCandidate for inbound chat messages (native LLM).
  #
  # On: object.created (comm_message, channel=chat, direction=inbound)
  # Creates: comm_response_candidate (status=approved if auto_approve_responses=True)
  # Relations: response_to
  #
  # The runtime drives the LLM (emitting llm.requested/llm.responded events)
  # and hands us ``output`` — the raw model text. We parse the ChatReply
  # shape ({"reply": "..."}) and map reply onto a CommResponseCandidate;
  # chat_responder then writes it to the ChatTurn.
  @[Chronicle::Packs::Annotations::LLMBehavior(name: "chat_llm_responder", on: ["object.created"], where: {"type" => "comm_message", "data.direction" => "inbound", "data.metadata.conversational" => true, "data.metadata.reply_gate" => "open"}, description: ResponderPrompt::DESCRIPTION, max_tokens: 1024, temperature: 0.7, creates: ["comm_response_candidate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream chat_llm_responder reply/candidate branches
  def chat_llm_responder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, output : String, settings : ChatSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?
    msg_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    thread_id = msg_data["thread_id"]?.try(&.as_s?)
    frame_id = msg_data["frame_id"]?.try(&.as_s?)
    msg_meta = msg_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any

    # The prior conversation reaches this LLM call via the ChatContext that
    # chat_context_assembler linked to this message: the depth-1 view below
    # captures it, the runtime serializes it into the prompt, and the model
    # output is the reply. "How many prior turns were shown" is recorded on
    # that ChatContext object (chat_context.turn_count).
    reply = begin
      parsed = JSON.parse(output)
      parsed["reply"]?.try(&.as_s?)
    rescue
      nil
    end
    response_content = (reply || output).strip
    return if response_content.empty?

    status = settings.auto_approve_responses? ? "approved" : "proposed"

    begin
      candidate = graph.add_object("comm_response_candidate", {"message_id" => JSON::Any.new(msg_id), "thread_id" => (thread_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(thread_id)), "channel" => JSON::Any.new(msg_data["channel"]?.try(&.as_s?) || "chat"), "content" => JSON::Any.new(response_content), "status" => JSON::Any.new(status), "created_by_behavior" => JSON::Any.new("chat_llm_responder"), "frame_id" => (frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id)), "metadata" => JSON::Any.new({"adapter" => (msg_meta["adapter"]? || JSON::Any.new({} of String => JSON::Any))} of String => JSON::Any)}.to_json, actor: "chat_llm_responder")
      graph.add_relation(candidate.id, msg_id, "response_to", actor: "chat_llm_responder")
    rescue
    end

    nil
  end

  # ── chat_deflection_responder ─────────────────────────────────────────────

  # Serve gated senders a bounded template reply — no LLM, no tools.
  #
  # On: object.created (comm_message, channel=chat, inbound, reply_gate=deflect)
  # Creates: comm_response_candidate (status=approved, metadata.gated=true)
  # Relations: response_to
  #
  # The mirror of chat_llm_responder for the deflect branch of the reply
  # gate: one declarative predicate each, so the split is visible in the
  # behavior map. Deflection is a decision, not silence — the sender gets a
  # polite fixed answer, the LLM is never invoked, and the gate verdict is
  # auditable on both the message and the candidate.
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_deflection_responder", on: ["object.created"], where: {"type" => "comm_message", "data.direction" => "inbound", "data.metadata.conversational" => true, "data.metadata.reply_gate" => "deflect"}, creates: ["comm_response_candidate"])]
  def chat_deflection_responder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?
    msg_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    meta = msg_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any

    begin
      candidate = graph.add_object("comm_response_candidate", {"message_id" => JSON::Any.new(msg_id), "thread_id" => (msg_data["thread_id"]?.try(&.as_s?)).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil), "channel" => JSON::Any.new(msg_data["channel"]?.try(&.as_s?) || "chat"), "content" => JSON::Any.new(settings.deflection_message), "status" => JSON::Any.new("approved"), "created_by_behavior" => JSON::Any.new("chat_deflection_responder"), "frame_id" => (msg_data["frame_id"]?.try(&.as_s?)).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil), "metadata" => JSON::Any.new({"gated" => JSON::Any.new(true), "reply_gate_reason" => JSON::Any.new(meta["reply_gate_reason"]?.try(&.as_s?)), "adapter" => (meta["adapter"]? || JSON::Any.new({} of String => JSON::Any))} of String => JSON::Any)}.to_json, actor: "chat_deflection_responder")
      graph.add_relation(candidate.id, msg_id, "response_to", actor: "chat_deflection_responder")
    rescue
    end

    nil
  end

  # ── chat_responder ────────────────────────────────────────────────────────

  # Deliver approved chat responses by updating ChatTurn.assistant_message.
  #
  # On: object.created (comm_response_candidate, channel=chat, status=approved)
  # Patches: chat_turn.assistant_message + response_candidate_id
  #
  # Writing the assistant_message back onto the ChatTurn is what makes the
  # completed Q&A part of the graph — so the next turn's chat_context_assembler
  # reads it straight from the graph (no in-process history needed).
  @[Chronicle::Packs::Annotations::Behavior(name: "chat_responder", on: ["object.created"], where: {"type" => "comm_response_candidate"})]
  def chat_responder(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : ChatSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["status"]?.try(&.as_s?) == "approved"

    message_id = data["message_id"]?.try(&.as_s?)
    response_content = data["content"]?.try(&.as_s?) || ""

    # Resolve the ChatTurn to patch. The cache is the hot path; if it misses
    # (e.g. after a restart), fall back to the graph view — the turn records
    # its comm_message_id, so the mapping is always recoverable.
    turn_id = message_id.try { |mid| message_to_turn[mid]? }
    if turn_id.nil?
      graph.objects("chat_turn").each do |turn|
        if JSON.parse(turn.data)["comm_message_id"]?.try(&.as_s?) == message_id
          turn_id = turn.id
          break
        end
      end
    end

    if turn_id
      begin
        _merge_patch(graph, turn_id, {"assistant_message" => JSON::Any.new(response_content), "response_candidate_id" => JSON::Any.new(candidate_id)})
      rescue
      end
    end

    nil
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json)
  end
end

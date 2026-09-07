require "json"
require "time"

module Chronicle::Packs::Email
  # Email Pack behaviors. Ported from upstream packs/email/behaviors.py.
  #
  # email_ingester  — email_message.created → Source + CommMessage + EmailThread
  # reply_drafter   — comm_response_candidate.created (channel=email) → EmailDraft
  # send_approver   — email_draft.created → approval gate or auto-approve
  #
  # Registries are in-process caches keyed by RFC 2822 Message-ID /
  # thread-key. Every value is also derivable from the graph; behaviors
  # fall back to graph lookups on a cache miss. Call clear_email_registry
  # between test fixtures (and to simulate an API-server restart).
  #
  # Approval policy: External = recipient not in owner_email_addresses and
  # not in trusted_domains. If external AND require_approval_for_external:
  # creates Action(approval_request, risk_class=high). Internal: auto-approves
  # draft + comm_response_candidate directly (patch_object cannot re-trigger
  # object.created behaviors, so the approved→sent dispatch chain is handled
  # inline, mirroring upstream).

  # message_id → email_message object_id (dedup by RFC 2822 Message-ID).
  class_property email_message_registry = {} of String => String

  # thread_key → {"email_thread_id", "comm_thread_id"}.
  class_property email_thread_registry = {} of String => Hash(String, JSON::Any)

  # email_message_id → comm_message_id.
  class_property email_to_comm_message = {} of String => String

  # response_candidate_id → email_draft_id.
  class_property candidate_to_draft = {} of String => String

  # Reset all registries — call between test fixtures.
  def self.clear_email_registry : Nil
    self.email_message_registry = {} of String => String
    self.email_thread_registry = {} of String => Hash(String, JSON::Any)
    self.email_to_comm_message = {} of String => String
    self.candidate_to_draft = {} of String => String
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Strip Re:/Fwd:/Fw: prefixes from an email subject (loop until none left).
  def self._strip_re_fwd(subject : String) : String
    cleaned = subject.strip
    loop do
      lower = cleaned.downcase
      if lower.starts_with?("re:") || lower.starts_with?("fwd:") || lower.starts_with?("fw:")
        idx = cleaned.index(":")
        break if idx.nil?
        cleaned = cleaned[(idx + 1)..].strip
      else
        break
      end
    end
    cleaned
  end

  # True if addr is an owner address or from a trusted domain.
  def self._is_internal(addr : String, owner_addrs : Array(String), trusted_domains : Array(String)) : Bool
    return true if owner_addrs.includes?(addr)
    domain = addr.includes?("@") ? addr.split("@").last.downcase : ""
    !domain.empty? && trusted_domains.map(&.downcase).includes?(domain)
  end

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json)
  end

  # Translate an EmailMessage into Source + CommMessage + EmailThread.
  @[Chronicle::Packs::Annotations::Behavior(name: "email_ingester", on: ["object.created"], where: {"type" => "email_message"}, creates: ["source", "comm_message", "email_thread"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream email_ingester dedup/thread branches
  def email_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EmailSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    email_obj_id = payload["id"]?.try(&.as_s?)
    return if email_obj_id.nil?
    em = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    message_id = em["message_id"]?.try(&.as_s?) || email_obj_id
    now = _now_iso

    # ── Dedup ───────────────────────────────────────────────────────────────
    return if email_message_registry.has_key?(message_id)
    email_message_registry[message_id] = email_obj_id

    from_addr = em["from_addr"]?.try(&.as_s?) || ""
    to_addrs = _as_str_list(em["to_addrs"]?)
    cc_addrs = _as_str_list(em["cc_addrs"]?)
    subject = em["subject"]?.try(&.as_s?) || ""
    body_text = (em["body_text"]?.try(&.as_s?) || "")[0, settings.max_body_length]
    thread_id_hint = em["thread_id"]?.try(&.as_s?) || em["in_reply_to"]?.try(&.as_s?) || message_id
    received_at = em["received_at"]?.try(&.as_s?) || now

    # ── 1. Resolve or create EmailThread ───────────────────────────────────
    thread_key = thread_id_hint
    email_thread_id : String? = nil

    if reg = email_thread_registry[thread_key]?
      email_thread_id = reg["email_thread_id"]?.try(&.as_s?)
      begin
        existing = graph.get_object(email_thread_id.to_s)
        if existing
          current_addrs = _as_str_list(JSON.parse(existing.data)["participant_addrs"]?)
          new_addrs = (current_addrs + [from_addr] + to_addrs + cc_addrs).uniq
          new_count = (JSON.parse(existing.data)["message_count"]?.try(&.as_i?) || 0) + 1
          _merge_patch(graph, email_thread_id.to_s, {
            "participant_addrs" => JSON::Any.new(new_addrs.map { |addr| JSON::Any.new(addr) }),
            "message_count"     => JSON::Any.new(new_count),
            "last_message_at"   => JSON::Any.new(received_at),
          })
        end
      rescue
      end
    elsif settings.auto_create_threads?
      begin
        all_participants = ([from_addr] + to_addrs + cc_addrs).uniq
        clean_subject = _strip_re_fwd(subject)
        email_thread = graph.add_object("email_thread", EmailThread.new(
          thread_id: thread_id_hint,
          subject: clean_subject,
          participant_addrs: all_participants,
          message_count: 1,
          last_message_at: received_at,
          first_message_id: message_id,
        ).to_json, actor: "email_ingester")
        email_thread_id = email_thread.id
        email_thread_registry[thread_key] = {
          "email_thread_id" => JSON::Any.new(email_thread_id),
          "comm_thread_id"  => JSON::Any.new(nil),
        }
      rescue
      end
    end

    if email_thread_id
      begin
        graph.add_relation(email_thread_id, email_obj_id, "email_thread_contains", actor: "email_ingester")
      rescue
      end
    end

    # ── 2. Create Core Source ───────────────────────────────────────────────
    source_id = begin
      source = graph.add_object("source", {
        "kind"       => JSON::Any.new("email"),
        "content"    => JSON::Any.new(body_text),
        "channel"    => JSON::Any.new("email"),
        "sender_ref" => JSON::Any.new(from_addr),
        "metadata"   => JSON::Any.new({
          "message_id"  => JSON::Any.new(message_id),
          "subject"     => JSON::Any.new(subject),
          "to_addrs"    => JSON::Any.new(to_addrs.map { |addr| JSON::Any.new(addr) }),
          "cc_addrs"    => JSON::Any.new(cc_addrs.map { |addr| JSON::Any.new(addr) }),
          "thread_id"   => JSON::Any.new(thread_id_hint),
          "received_at" => JSON::Any.new(received_at),
        }),
      }.to_json, actor: "email_ingester")
      source.id
    rescue
      return
    end

    # ── 3. Create CommMessage ───────────────────────────────────────────────
    begin
      comm_msg = graph.add_object("comm_message", {
        "channel"    => JSON::Any.new("email"),
        "sender_ref" => JSON::Any.new(from_addr),
        "content"    => JSON::Any.new(body_text),
        "direction"  => JSON::Any.new("inbound"),
        "source_id"  => JSON::Any.new(source_id),
        "metadata"   => JSON::Any.new({
          "subject"        => JSON::Any.new(subject),
          "thread_id_hint" => JSON::Any.new(thread_id_hint),
          "message_id"     => JSON::Any.new(message_id),
          "to_addrs"       => JSON::Any.new(to_addrs.map { |addr| JSON::Any.new(addr) }),
          "cc_addrs"       => JSON::Any.new(cc_addrs.map { |addr| JSON::Any.new(addr) }),
        }),
      }.to_json, actor: "email_ingester")
      email_to_comm_message[email_obj_id] = comm_msg.id
      graph.add_relation(comm_msg.id, source_id.to_s, "derived_from_source", actor: "email_ingester")
    rescue
    end
  end

  # Format a CommResponseCandidate as an EmailDraft.
  @[Chronicle::Packs::Annotations::Behavior(name: "reply_drafter", on: ["object.created"], where: {"type" => "comm_response_candidate"}, creates: ["email_draft"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream reply_drafter header branches
  def reply_drafter(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EmailSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?
    cdata = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless cdata["channel"]?.try(&.as_s?) == "email"

    message_id = cdata["message_id"]?.try(&.as_s?)
    content = cdata["content"]?.try(&.as_s?) || ""
    artifact_id = cdata["artifact_id"]?.try(&.as_s?)
    thread_id = cdata["thread_id"]?.try(&.as_s?)

    to_addrs = [] of String
    subject = "Re: (no subject)"
    in_reply_to_message_id : String? = nil

    if message_id
      begin
        orig_msg = graph.get_object(message_id)
        if orig_msg
          sender = JSON.parse(orig_msg.data)["sender_ref"]?.try(&.as_s?) || ""
          to_addrs = [sender] unless sender.empty?
          meta = JSON.parse(orig_msg.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any
          raw_subject = meta["subject"]?.try(&.as_s?) || ""
          subject = "Re: #{_strip_re_fwd(raw_subject)}" unless raw_subject.empty?
          in_reply_to_message_id = meta["message_id"]?.try(&.as_s?)
        end
      rescue
      end
    end

    body_parts = [content]
    if settings.draft_signature && !settings.draft_signature.empty?
      body_parts << "\n\n--\n#{settings.draft_signature}"
    end
    body = body_parts.join("\n")

    begin
      draft = graph.add_object("email_draft", EmailDraft.new(
        to_addrs: to_addrs,
        cc_addrs: [] of String,
        subject: subject,
        body: body,
        in_reply_to_message_id: in_reply_to_message_id,
        response_candidate_id: candidate_id,
        artifact_id: artifact_id,
        status: "draft",
        requires_approval: settings.require_approval_for_external?,
        metadata: {
          "reply_to_comm_message_id" => JSON::Any.new(message_id),
          "thread_id"                => JSON::Any.new(thread_id),
        },
      ).to_json, actor: "reply_drafter")
      candidate_to_draft[candidate_id] = draft.id
      graph.add_relation(draft.id, candidate_id, "draft_from_candidate", actor: "reply_drafter")
    rescue
    end
  end

  # Gate outbound email sends with an approval policy.
  @[Chronicle::Packs::Annotations::Behavior(name: "send_approver", on: ["object.created"], where: {"type" => "email_draft"}, creates: ["action"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream send_approver external/internal branches
  def send_approver(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EmailSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    draft_id = payload["id"]?.try(&.as_s?)
    return if draft_id.nil?
    ddata = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless ddata["status"]?.try(&.as_s?) == "draft"

    to_addrs = _as_str_list(ddata["to_addrs"]?)
    owner_addrs = settings.owner_email_addresses
    trusted_domains = settings.trusted_domains

    has_external = to_addrs.any? { |addr| !_is_internal(addr, owner_addrs, trusted_domains) }
    needs_approval = settings.require_approval_for_external? && (has_external || to_addrs.empty?)

    if needs_approval
      joined_to = to_addrs.join(", ")
      recipient_label = joined_to.empty? ? "(no recipients)" : joined_to
      begin
        graph.add_object("action", {
          "kind"        => JSON::Any.new("approval_request"),
          "description" => JSON::Any.new(
            "Approve outbound email draft '#{ddata["subject"]?.try(&.as_s?) || ""}' " \
            "to #{recipient_label}"
          ),
          "status"      => JSON::Any.new("proposed"),
          "proposed_by" => JSON::Any.new("send_approver"),
          "risk_class"  => JSON::Any.new("high"),
          "input_data"  => JSON::Any.new({
            "email_draft_id" => JSON::Any.new(draft_id),
            "to_addrs"       => JSON::Any.new(to_addrs.map { |addr| JSON::Any.new(addr) }),
            "subject"        => JSON::Any.new(ddata["subject"]?.try(&.as_s?) || ""),
          }),
          "metadata" => JSON::Any.new({"email_draft_id" => JSON::Any.new(draft_id)}),
        }.to_json, actor: "send_approver")
      rescue
      end
    else
      # Internal auto-approve: mark draft and candidate as "sent" directly.
      # Cannot use "approved" → patch → response_dispatcher chain because
      # patch_object does NOT re-trigger object.created behaviors.
      begin
        _merge_patch(graph, draft_id, {"status" => JSON::Any.new("sent")})
      rescue
      end

      if response_candidate_id = ddata["response_candidate_id"]?.try(&.as_s?)
        begin
          _merge_patch(graph, response_candidate_id, {"status" => JSON::Any.new("sent")})
        rescue
        end
      end
    end
  end

  private def self._as_str_list(value : JSON::Any?) : Array(String)
    value.try(&.as_a?.try(&.map(&.as_s))) || [] of String
  end
end

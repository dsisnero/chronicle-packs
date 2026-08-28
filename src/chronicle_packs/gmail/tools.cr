require "json"
require "digest"
require "set"

module Chronicle::Packs::Gmail
  # Gmail exploration, bounded sync, and effect proposals. Ported from
  # upstream packs/gmail/tools.py.

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._stable(prefix : String, *parts) : String
    material = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  def self._validated_route(route : String) : String
    normalized = route.strip.downcase
    unless Usage::Categories::CONNECTION_PATHS.includes?(normalized)
      raise ArgumentError.new("unknown Gmail connection route #{route.inspect}")
    end
    normalized
  end

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json, actor: "gmail")
  end

  def self._capability_call(
    graph : Chronicle::GraphProjection,
    *,
    operation : String,
    action_class : String,
    risk_class : String,
    input_data : Hash(String, JSON::Any),
    metadata : Hash(String, JSON::Any),
    proposed_by : String,
    route : String = "composio",
  ) : Chronicle::GraphObject
    route = _validated_route(route)
    explicit = action_class.in?({"R2", "R3", "R4"})
    graph.add_object("capability_call", ToolGateway::CapabilityCall.new(
      provider_id: "",
      provider_name: "gmail",
      capability_name: operation,
      input_data: input_data,
      credential_ref_name: nil,
      credential_ref_id: nil,
      risk_class: ToolGateway::RiskClass.parse?(risk_class) || ToolGateway::RiskClass::Low,
      action_class: action_class,
      status: ToolGateway::CallStatus::Proposed,
      proposed_by: proposed_by,
      frame_id: nil,
      proposed_at: nil,
      metadata: {
        "route"                      => JSON::Any.new(route),
        "gmail"                      => JSON::Any.new(metadata),
        "requires_explicit_approval" => JSON::Any.new(explicit),
      },
    ).to_json, actor: "gmail")
  end

  def self.request_gmail_exploration_fn(
    graph : Chronicle::GraphProjection,
    *,
    user_id : String,
    connected_account_id : String,
    budget : Int32 = 2,
    force : Bool = false,
    route : String = "composio",
  ) : Hash(String, JSON::Any)
    route = _validated_route(route)
    raise ArgumentError.new("Gmail exploration needs budget >= 2 for profile and labels") if budget < 2
    base_key = ToolGateway.stable_integration_id("gmail_exploration", route, connected_account_id)
    prior = graph.objects(type: "integration_exploration").select do |obj|
      meta = (JSON.parse(obj.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any)
      meta["base_exploration_key"]?.try(&.as_s?) == base_key || meta["exploration_key"]?.try(&.as_s?) == base_key
    end
    exploration_key =
      if force
        ToolGateway.stable_integration_id("gmail_exploration_refresh", route, connected_account_id, prior.size + 1)
      else
        base_key
      end
    existing = graph.objects(type: "integration_exploration").find do |obj|
      data = JSON.parse(obj.data)
      meta = (data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)
      meta["exploration_key"]?.try(&.as_s?) == exploration_key &&
        data["status"]?.try(&.as_s?).in?({"proposed", "partial", "completed"})
    end
    if existing
      existing_data = JSON.parse(existing.data).as_h
      return {
        "ok"             => JSON::Any.new(true),
        "created"        => JSON::Any.new(false),
        "exploration_id" => JSON::Any.new(existing.id),
        "call_ids"       => existing_data["probe_call_ids"]? || JSON::Any.new([] of JSON::Any),
      }
    end

    calls = [] of Chronicle::GraphObject
    [{"profile.get", "profile"}, {"labels.list", "labels"}].each do |operation, probe|
      call = _capability_call(
        graph,
        operation: operation,
        action_class: "R0",
        risk_class: "low",
        input_data: {"user_id" => JSON::Any.new(user_id), "connected_account_id" => JSON::Any.new(connected_account_id)},
        metadata: {
          "kind"                 => JSON::Any.new("exploration"),
          "probe"                => JSON::Any.new(probe),
          "exploration_key"      => JSON::Any.new(exploration_key),
          "connected_account_id" => JSON::Any.new(connected_account_id),
        },
        proposed_by: "gmail.integration_explorer",
        route: route,
      )
      calls << call
    end
    receipt, _created = ToolGateway.record_exploration_fn(
      graph,
      service: "gmail",
      account_ref: "pending:#{connected_account_id}",
      route: route,
      probe_call_ids: calls.map(&.id),
      budget: budget,
      status: "proposed",
      metadata: {
        "exploration_key"      => JSON::Any.new(exploration_key),
        "base_exploration_key" => JSON::Any.new(base_key),
        "connected_account_id" => JSON::Any.new(connected_account_id),
        "forced_refresh"       => JSON::Any.new(force),
        "route"                => JSON::Any.new(route),
      },
    )
    {
      "ok"             => JSON::Any.new(true),
      "created"        => JSON::Any.new(true),
      "exploration_id" => JSON::Any.new(receipt.id),
      "call_ids"       => JSON::Any.new(calls.map { |call| JSON::Any.new(call.id) }),
    }
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream request_gmail_backfill_fn resume/restart branches
  def self.request_gmail_backfill_fn(
    graph : Chronicle::GraphProjection,
    *,
    source_surface_id : String,
    account_ref : String,
    user_id : String,
    connected_account_id : String,
    query : String = "newer_than:30d",
    page_size : Int32 = 25,
    max_messages : Int32 = 250,
    max_pages : Int32 = 10,
    route : String = "composio",
  ) : Hash(String, JSON::Any)
    route = _validated_route(route)
    identity = _stable("gmail_sync", source_surface_id, "backfill", query, max_messages, max_pages)
    existing = graph.objects(type: "gmail_sync_run").find { |obj| JSON.parse(obj.data)["run_identity"]?.try(&.as_s?) == identity }
    if existing && JSON.parse(existing.data)["status"]?.try(&.as_s?).in?({"running", "completed", "partial"})
      ed = JSON.parse(existing.data).as_h
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "run_id" => JSON::Any.new(existing.id), "call_ids" => ed["call_ids"]? || JSON::Any.new([] of JSON::Any)}
    end
    if existing && JSON.parse(existing.data)["status"]?.try(&.as_s?) == "failed"
      ed = JSON.parse(existing.data).as_h
      active_profile = graph.objects(type: "integration_profile").find do |obj|
        pd = JSON.parse(obj.data)
        pd["service"]?.try(&.as_s?) == "gmail" && pd["account_ref"]?.try(&.as_s?) == account_ref && pd["status"]?.try(&.as_s?) == "active"
      end
      prior_profile_id = (ed["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["integration_profile_id"]?.try(&.as_s?)
      structural_failure = ed["error_code"]?.try(&.as_s?).in?({"unexpected_shape", "auth_expired"})
      if structural_failure && (active_profile.nil? || active_profile.id == prior_profile_id)
        return {
          "ok"            => JSON::Any.new(false),
          "created"       => JSON::Any.new(false),
          "retry_blocked" => JSON::Any.new(true),
          "run_id"        => JSON::Any.new(existing.id),
          "call_ids"      => ed["call_ids"]? || JSON::Any.new([] of JSON::Any),
          "reason"        => JSON::Any.new("reconnect or complete profile re-exploration before retrying this backfill"),
        }
      end
      metadata = (ed["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
      metadata["route"] = JSON::Any.new(route)
      metadata["integration_profile_id"] = JSON::Any.new(active_profile.id) if active_profile
      _merge_patch(graph, existing.id, {
        "status"          => JSON::Any.new("running"),
        "error_code"      => JSON::Any.new(nil),
        "error"           => JSON::Any.new(nil),
        "next_page_token" => JSON::Any.new(nil),
        "metadata"        => JSON::Any.new(metadata),
      })
      call = propose_gmail_page_fn(graph, existing)
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "resumed" => JSON::Any.new(true), "run_id" => JSON::Any.new(existing.id), "call_ids" => JSON::Any.new([JSON::Any.new(call.id)])}
    end

    active_profile = graph.objects(type: "integration_profile").find do |obj|
      pd = JSON.parse(obj.data)
      pd["service"]?.try(&.as_s?) == "gmail" && pd["account_ref"]?.try(&.as_s?) == account_ref && pd["status"]?.try(&.as_s?) == "active"
    end
    run = graph.add_object("gmail_sync_run", GmailSyncRun.new(
      run_identity: identity,
      source_surface_id: source_surface_id,
      account_ref: account_ref,
      user_id: user_id,
      connected_account_id: connected_account_id,
      mode: SyncMode::Backfill,
      page_size: page_size,
      max_messages: max_messages,
      max_pages: max_pages,
      query: query,
      start_history_id: nil,
      next_page_token: nil,
      pages_completed: 0,
      messages_imported: 0,
      call_ids: [] of String,
      pending_message_ids: [] of String,
      completed_message_ids: [] of String,
      missing_message_ids: [] of String,
      status: SyncStatus::Running,
      latest_history_id: nil,
      deleted_message_ids: [] of String,
      tombstones_recorded: 0,
      error_code: nil,
      error: nil,
      metadata: {
        "restart_strategy"       => JSON::Any.new("query_overlap_plus_evidence_dedup"),
        "integration_profile_id" => active_profile ? JSON::Any.new(active_profile.id) : JSON::Any.new(nil),
        "route"                  => JSON::Any.new(route),
      },
    ).to_json, actor: "gmail")
    call = propose_gmail_page_fn(graph, run)
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "run_id" => JSON::Any.new(run.id), "call_ids" => JSON::Any.new([JSON::Any.new(call.id)])}
  end

  def self.propose_gmail_page_fn(graph : Chronicle::GraphProjection, run : Chronicle::GraphObject, *, page_token : String = "") : Chronicle::GraphObject
    data = JSON.parse(run.data).as_h
    call = _capability_call(
      graph,
      operation: "messages.fetch",
      action_class: "R0",
      risk_class: "low",
      input_data: {
        "user_id"              => JSON::Any.new(data["user_id"]?.try(&.as_s?) || ""),
        "connected_account_id" => JSON::Any.new(data["connected_account_id"]?.try(&.as_s?) || ""),
        "query"                => JSON::Any.new(data["query"]?.try(&.as_s?) || ""),
        "page_token"           => JSON::Any.new(page_token),
        "max_results"          => JSON::Any.new(data["page_size"]?.try(&.as_i?) || 0),
        "include_payload"      => JSON::Any.new(true),
      },
      metadata: {
        "kind"          => JSON::Any.new("backfill"),
        "run_id"        => JSON::Any.new(run.id),
        "page_sequence" => JSON::Any.new((data["pages_completed"]?.try(&.as_i?) || 0) + 1),
      },
      proposed_by: "gmail.backfill",
      route: (data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio",
    )
    graph.add_relation(run.id, call.id, "gmail_sync_call", actor: "gmail")
    call_ids = (data["call_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s) + [call.id]
    _merge_patch(graph, run.id, {
      "call_ids"        => JSON::Any.new(call_ids.map { |id| JSON::Any.new(id) }),
      "next_page_token" => page_token.empty? ? JSON::Any.new(nil) : JSON::Any.new(page_token),
    })
    call
  end

  def self.request_gmail_poll_fn(
    graph : Chronicle::GraphProjection,
    *,
    source_surface_id : String,
    account_ref : String,
    user_id : String,
    connected_account_id : String,
    start_history_id : String,
    max_messages : Int32 = 100,
    route : String = "composio",
  ) : Hash(String, JSON::Any)
    route = _validated_route(route)
    raise ArgumentError.new("start_history_id is required") if start_history_id.empty?
    matching = graph.objects(type: "gmail_sync_run").select do |obj|
      d = JSON.parse(obj.data)
      d["source_surface_id"]?.try(&.as_s?) == source_surface_id &&
        d["mode"]?.try(&.as_s?) == "poll" &&
        d["start_history_id"]?.try(&.as_s?) == start_history_id
    end
    active = matching.reverse.find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?).in?({"proposed", "running"}) }
    if active
      ad = JSON.parse(active.data).as_h
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "already_running" => JSON::Any.new(true), "run_id" => JSON::Any.new(active.id), "call_ids" => ad["call_ids"]? || JSON::Any.new([] of JSON::Any)}
    end
    existing = matching.last?
    if existing
      ed = JSON.parse(existing.data).as_h
      if ed["status"]?.try(&.as_s?) == "failed" && ed["error_code"]?.try(&.as_s?) == "rate_limited"
        _merge_patch(graph, existing.id, {"status" => JSON::Any.new("running"), "error_code" => JSON::Any.new(nil), "error" => JSON::Any.new(nil)})
        retry_call = _capability_call(
          graph,
          operation: "history.list", action_class: "R0", risk_class: "low",
          input_data: {
            "user_id"              => JSON::Any.new(user_id),
            "connected_account_id" => JSON::Any.new(connected_account_id),
            "start_history_id"     => JSON::Any.new(start_history_id),
            "max_results"          => JSON::Any.new(max_messages),
          },
          metadata: {"kind" => JSON::Any.new("history"), "run_id" => JSON::Any.new(existing.id), "retry" => JSON::Any.new(true)},
          proposed_by: "gmail.poll",
          route: route,
        )
        graph.add_relation(existing.id, retry_call.id, "gmail_sync_call", actor: "gmail")
        ed_call_ids = (ed["call_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s) + [retry_call.id]
        _merge_patch(graph, existing.id, {"call_ids" => JSON::Any.new(ed_call_ids.map { |id| JSON::Any.new(id) })})
        return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "resumed" => JSON::Any.new(true), "run_id" => JSON::Any.new(existing.id), "call_ids" => JSON::Any.new([JSON::Any.new(retry_call.id)])}
      end
    end
    identity = _stable("gmail_sync", source_surface_id, "poll", start_history_id, matching.size + 1)
    run = graph.add_object("gmail_sync_run", GmailSyncRun.new(
      run_identity: identity,
      source_surface_id: source_surface_id,
      account_ref: account_ref,
      user_id: user_id,
      connected_account_id: connected_account_id,
      mode: SyncMode::Poll,
      page_size: Math.min(max_messages, 100),
      max_messages: max_messages,
      max_pages: 1,
      query: "",
      start_history_id: start_history_id,
      next_page_token: nil,
      pages_completed: 0,
      messages_imported: 0,
      call_ids: [] of String,
      pending_message_ids: [] of String,
      completed_message_ids: [] of String,
      missing_message_ids: [] of String,
      status: SyncStatus::Running,
      latest_history_id: nil,
      deleted_message_ids: [] of String,
      tombstones_recorded: 0,
      error_code: nil,
      error: nil,
      metadata: {"route" => JSON::Any.new(route)},
    ).to_json, actor: "gmail")
    call = _capability_call(
      graph,
      operation: "history.list", action_class: "R0", risk_class: "low",
      input_data: {
        "user_id"              => JSON::Any.new(user_id),
        "connected_account_id" => JSON::Any.new(connected_account_id),
        "start_history_id"     => JSON::Any.new(start_history_id),
        "max_results"          => JSON::Any.new(max_messages),
      },
      metadata: {"kind" => JSON::Any.new("history"), "run_id" => JSON::Any.new(run.id)},
      proposed_by: "gmail.poll",
      route: route,
    )
    graph.add_relation(run.id, call.id, "gmail_sync_call", actor: "gmail")
    _merge_patch(graph, run.id, {"call_ids" => JSON::Any.new([JSON::Any.new(call.id)])})
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "run_id" => JSON::Any.new(run.id), "call_ids" => JSON::Any.new([JSON::Any.new(call.id)])}
  end

  def self.create_gmail_draft_candidate_fn(
    graph : Chronicle::GraphProjection,
    *,
    account_ref : String,
    connected_account_id : String,
    to : Array(String),
    subject : String,
    body : String,
    cc : Array(String)? = nil,
    bcc : Array(String)? = nil,
    thread_id : String? = nil,
    prediction_id : String? = nil,
    route : String = "composio",
  ) : {Chronicle::GraphObject, Bool}
    route = _validated_route(route)
    identity = _stable("gmail_draft", account_ref, to.join(","), subject, body, thread_id || "")
    existing = graph.objects(type: "gmail_draft_candidate").find { |obj| JSON.parse(obj.data)["draft_identity"]?.try(&.as_s?) == identity }
    if existing
      return {existing, false}
    end
    draft = graph.add_object("gmail_draft_candidate", GmailDraftCandidate.new(
      draft_identity: identity,
      account_ref: account_ref,
      connected_account_id: connected_account_id,
      idempotency_key: identity,
      to: to,
      cc: cc || [] of String,
      bcc: bcc || [] of String,
      subject: subject,
      body: body,
      thread_id: thread_id,
      status: DraftStatus::LocalDraft,
      provider_draft_id: nil,
      prediction_id: prediction_id,
      metadata: {"route" => JSON::Any.new(route)},
    ).to_json, actor: "gmail")
    {draft, true}
  end

  def self.reprocess_gmail_evidence_fn(
    graph : Chronicle::GraphProjection,
    *,
    source_surface_id : String,
    max_items : Int32 = 250,
  ) : Hash(String, JSON::Any)
    raise ArgumentError.new("max_items must be between 1 and 1000") if max_items < 1 || max_items > 1000
    run_ids = Set(String).new
    graph.objects(type: "activity_evidence").each do |obj|
      ed = JSON.parse(obj.data)
      if ed["status"]?.try(&.as_s?) == "current" && ed["source_surface_id"]?.try(&.as_s?) == source_surface_id
        run_ids.add((ed["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any)["connector_run_id"]?.try(&.as_s?) || "")
      end
    end
    runs = graph.objects(type: "gmail_sync_run").select { |obj| run_ids.includes?(obj.id) }
    remaining = max_items
    summaries = [] of Hash(String, JSON::Any)
    runs.each do |run|
      break if remaining <= 0
      _native, summary = materialize_gmail_run_fn(graph, run, reader: graph, reprocess: true, max_items: remaining)
      summaries << ({"run_id" => JSON::Any.new(run.id)}.merge(summary))
      remaining -= summary["messages"]?.try(&.as_i?) || 0
    end
    {
      "ok"                   => JSON::Any.new(true),
      "source_surface_id"    => JSON::Any.new(source_surface_id),
      "messages_reprocessed" => JSON::Any.new(max_items - remaining),
      "runs"                 => JSON::Any.new(summaries.map { |row| JSON::Any.new(row) }),
      "provider_contacted"   => JSON::Any.new(false),
    }
  end

  def self._existing_draft_call(graph : Chronicle::GraphProjection, draft_id : String, kind : String) : Chronicle::GraphObject?
    graph.objects(type: "capability_call").find do |obj|
      d = JSON.parse(obj.data)
      gmail_meta = (d["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["gmail"]?.try(&.as_h) || {} of String => JSON::Any
      gmail_meta["kind"]?.try(&.as_s?) == kind &&
        gmail_meta["draft_id"]?.try(&.as_s?) == draft_id &&
        !d["status"]?.try(&.as_s?).in?({"failed", "rejected"})
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream request_gmail_draft_sync_fn create-call branches
  def self.request_gmail_draft_sync_fn(graph : Chronicle::GraphProjection, *, draft_id : String, user_id : String) : Hash(String, JSON::Any)
    draft = graph.get_object(draft_id)
    raise ArgumentError.new("gmail draft candidate not found") if draft.nil? || draft.type != "gmail_draft_candidate"
    dd = JSON.parse(draft.data).as_h
    if dd["status"]?.try(&.as_s?).in?({"synced", "send_proposed", "sent"})
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "draft_id" => JSON::Any.new(draft.id), "provider_draft_id" => dd["provider_draft_id"]? || JSON::Any.new(nil)}
    end
    if existing = _existing_draft_call(graph, draft.id, "draft_create")
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "draft_id" => JSON::Any.new(draft.id), "call_id" => JSON::Any.new(existing.id)}
    end
    recipients = (dd["to"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).map(&.strip).reject(&.empty?)
    raise ArgumentError.new("Gmail draft needs at least one recipient") if recipients.empty?
    call = _capability_call(
      graph,
      operation: "drafts.create",
      action_class: "R2",
      risk_class: "medium",
      input_data: {
        "user_id"              => JSON::Any.new(user_id),
        "connected_account_id" => JSON::Any.new(dd["connected_account_id"]?.try(&.as_s?) || ""),
        "recipient_email"      => JSON::Any.new(recipients.join(", ")),
        "subject"              => JSON::Any.new(dd["subject"]?.try(&.as_s?) || ""),
        "body"                 => JSON::Any.new(dd["body"]?.try(&.as_s?) || ""),
        "cc"                   => JSON::Any.new((dd["cc"]?.try(&.as_a) || [] of JSON::Any).map { |v| JSON::Any.new(v.as_s) }),
        "bcc"                  => JSON::Any.new((dd["bcc"]?.try(&.as_a) || [] of JSON::Any).map { |v| JSON::Any.new(v.as_s) }),
        "thread_id"            => JSON::Any.new(dd["thread_id"]?.try(&.as_s?) || ""),
        "is_html"              => JSON::Any.new(false),
        "idempotency_key"      => JSON::Any.new(dd["idempotency_key"]?.try(&.as_s?) || ""),
      },
      metadata: {"kind" => JSON::Any.new("draft_create"), "draft_id" => JSON::Any.new(draft.id)},
      proposed_by: "gmail.local_draft",
      route: (dd["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio",
    )
    graph.add_relation(draft.id, call.id, "gmail_draft_call", actor: "gmail")
    _merge_patch(graph, draft.id, {"status" => JSON::Any.new("sync_proposed")})
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "draft_id" => JSON::Any.new(draft.id), "call_id" => JSON::Any.new(call.id)}
  end

  def self.request_gmail_draft_send_fn(graph : Chronicle::GraphProjection, *, draft_id : String, user_id : String) : Hash(String, JSON::Any)
    draft = graph.get_object(draft_id)
    raise ArgumentError.new("gmail draft candidate not found") if draft.nil? || draft.type != "gmail_draft_candidate"
    dd = JSON.parse(draft.data).as_h
    if dd["status"]?.try(&.as_s?) == "sent"
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "draft_id" => JSON::Any.new(draft.id), "sent" => JSON::Any.new(true)}
    end
    if existing = _existing_draft_call(graph, draft.id, "draft_send")
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "draft_id" => JSON::Any.new(draft.id), "call_id" => JSON::Any.new(existing.id)}
    end
    provider_draft_id = dd["provider_draft_id"]?.try(&.as_s?) || ""
    if dd["status"]?.try(&.as_s?) != "synced" || provider_draft_id.empty?
      raise ArgumentError.new("Gmail draft must be synchronized before send can be proposed")
    end
    call = _capability_call(
      graph,
      operation: "drafts.send",
      action_class: "R3",
      risk_class: "high",
      input_data: {
        "user_id"              => JSON::Any.new(user_id),
        "connected_account_id" => JSON::Any.new(dd["connected_account_id"]?.try(&.as_s?) || ""),
        "draft_id"             => JSON::Any.new(provider_draft_id),
        "idempotency_key"      => JSON::Any.new("#{dd["idempotency_key"]?.try(&.as_s?) || ""}:send"),
      },
      metadata: {"kind" => JSON::Any.new("draft_send"), "draft_id" => JSON::Any.new(draft.id)},
      proposed_by: "gmail.synced_draft",
      route: (dd["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio",
    )
    graph.add_relation(draft.id, call.id, "gmail_draft_call", actor: "gmail")
    _merge_patch(graph, draft.id, {"status" => JSON::Any.new("send_proposed")})
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "draft_id" => JSON::Any.new(draft.id), "call_id" => JSON::Any.new(call.id)}
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "gmail tools require a bound graph (set Gmail.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "request_gmail_exploration", description: "Propose two budgeted R0 Gmail structure probes.", deterministic: true)]
  def request_gmail_exploration_tool(args : String) : String
    input = JSON.parse(args).as_h
    request_gmail_exploration_fn(
      bound_graph_or_raise,
      user_id: input["user_id"]?.try(&.as_s?) || "",
      connected_account_id: input["connected_account_id"]?.try(&.as_s?) || "",
      budget: input["budget"]?.try(&.as_i?) || 2,
      force: input["force"]?.try(&.as_bool?) || false,
      route: input["route"]?.try(&.as_s?) || "composio",
    ).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_gmail_backfill", description: "Start a bounded resumable Gmail backfill.", deterministic: true)]
  def request_gmail_backfill_tool(args : String) : String
    input = JSON.parse(args).as_h
    request_gmail_backfill_fn(
      bound_graph_or_raise,
      source_surface_id: input["source_surface_id"]?.try(&.as_s?) || "",
      account_ref: input["account_ref"]?.try(&.as_s?) || "",
      user_id: input["user_id"]?.try(&.as_s?) || "",
      connected_account_id: input["connected_account_id"]?.try(&.as_s?) || "",
      query: input["query"]?.try(&.as_s?) || "newer_than:30d",
      page_size: input["page_size"]?.try(&.as_i?) || 25,
      max_messages: input["max_messages"]?.try(&.as_i?) || 250,
      max_pages: input["max_pages"]?.try(&.as_i?) || 10,
      route: input["route"]?.try(&.as_s?) || "composio",
    ).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_gmail_poll", description: "Poll Gmail from a provider-stable history watermark.", deterministic: true)]
  def request_gmail_poll_tool(args : String) : String
    input = JSON.parse(args).as_h
    request_gmail_poll_fn(
      bound_graph_or_raise,
      source_surface_id: input["source_surface_id"]?.try(&.as_s?) || "",
      account_ref: input["account_ref"]?.try(&.as_s?) || "",
      user_id: input["user_id"]?.try(&.as_s?) || "",
      connected_account_id: input["connected_account_id"]?.try(&.as_s?) || "",
      start_history_id: input["start_history_id"]?.try(&.as_s?) || "",
      max_messages: input["max_messages"]?.try(&.as_i?) || 100,
      route: input["route"]?.try(&.as_s?) || "composio",
    ).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_gmail_draft_candidate", description: "Create a local R1 Gmail draft candidate; no provider write or send.", deterministic: true)]
  def create_gmail_draft_candidate_tool(args : String) : String
    input = JSON.parse(args).as_h
    to = input["to"]?.try(&.as_a?) ? input["to"].as_a.map(&.as_s) : [] of String
    draft, created = create_gmail_draft_candidate_fn(
      bound_graph_or_raise,
      account_ref: input["account_ref"]?.try(&.as_s?) || "",
      connected_account_id: input["connected_account_id"]?.try(&.as_s?) || "",
      to: to,
      subject: input["subject"]?.try(&.as_s?) || "",
      body: input["body"]?.try(&.as_s?) || "",
      route: input["route"]?.try(&.as_s?) || "composio",
    )
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "draft_id" => JSON::Any.new(draft.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_gmail_draft_sync", description: "Propose an R2 Gmail-hosted draft from a local R1 candidate.", deterministic: true)]
  def request_gmail_draft_sync_tool(args : String) : String
    input = JSON.parse(args).as_h
    request_gmail_draft_sync_fn(
      bound_graph_or_raise,
      draft_id: input["draft_id"]?.try(&.as_s?) || "",
      user_id: input["user_id"]?.try(&.as_s?) || "",
    ).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "request_gmail_draft_send", description: "Propose an outward R3 send of an existing Gmail draft.", deterministic: true)]
  def request_gmail_draft_send_tool(args : String) : String
    input = JSON.parse(args).as_h
    request_gmail_draft_send_fn(
      bound_graph_or_raise,
      draft_id: input["draft_id"]?.try(&.as_s?) || "",
      user_id: input["user_id"]?.try(&.as_s?) || "",
    ).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "reprocess_gmail_evidence", description: "Re-run local Gmail family projection over recorded evidence without provider contact.", deterministic: true)]
  def reprocess_gmail_evidence_tool(args : String) : String
    input = JSON.parse(args).as_h
    reprocess_gmail_evidence_fn(
      bound_graph_or_raise,
      source_surface_id: input["source_surface_id"]?.try(&.as_s?) || "",
      max_items: input["max_items"]?.try(&.as_i?) || 250,
    ).to_json
  end
end

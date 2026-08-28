require "json"
require "base64"
require "digest"
require "set"

module Chronicle::Packs::Gmail
  # Turn recorded Gmail route results into profiles, evidence, and cursors.
  # Ported from upstream packs/gmail/behaviors.py.

  # ── helpers ─────────────────────────────────────────────────────────────

  class_property event_seq = 0_u64

  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any), caused_by : String?, actor : String = "gmail") : Chronicle::Event
    seq = (self.event_seq += 1)
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{event_type.gsub('.', "_")}_#{seq}",
      type: event_type, actor: actor, caused_by: caused_by,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
  end

  def self._empty_value?(value : JSON::Any) : Bool
    raw = value.raw
    case raw
    when Nil
      true
    when String
      raw.empty?
    when Array
      raw.empty?
    when Hash
      raw.empty?
    else
      false
    end
  end

  def self._json(value : String) : Hash(String, JSON::Any)
    parsed =
      begin
        JSON.parse(value.empty? ? "{}" : value)
      rescue ex : JSON::ParseException
        raise ArgumentError.new("Gmail capability result is not JSON: #{ex}")
      end
    raise ArgumentError.new("Gmail capability result must be a JSON object") unless parsed.as_h?
    parsed.as_h
  end

  def self._read_route_payload(envelope : Hash(String, JSON::Any), settings : GmailSettings) : JSON::Any
    unless envelope["replay_mode"]?.try(&.as_s?) == "artifact"
      raise ArgumentError.new("Gmail route result is not replay-complete artifact data")
    end
    artifact_ref, digest = ActivityNormalizer::Replay.artifact_identity_from_locator(
      envelope["replay_artifact_locator"]?.try(&.as_s?) || ""
    )
    raw = ActivityNormalizer::Replay.read_artifact(
      artifact_ref,
      digest,
      settings.artifact_store_dir,
      max_bytes: settings.max_replay_payload_bytes,
    )
    JSON.parse(String.new(raw))
  end

  def self._unwrap(value : JSON::Any) : JSON::Any
    current = value
    5.times do
      h = current.as_h?
      break if h.nil?
      candidate = nil.as(JSON::Any?)
      {"response_data", "responseData", "data"}.each do |key|
        nested = h[key]?
        if nested.try(&.as_h?) || nested.try(&.as_a?)
          candidate = nested
          break
        end
      end
      break if candidate.nil?
      current = candidate.as(JSON::Any)
    end
    current
  end

  def self._find_key(value : JSON::Any, names : Array(String)) : JSON::Any?
    if h = value.as_h?
      names.each do |name|
        v = h[name]?
        return v if v && !_empty_value?(v)
      end
      h.each_value do |child|
        found = _find_key(child, names)
        return found if found && !_empty_value?(found)
      end
    elsif a = value.as_a?
      a.each do |child|
        found = _find_key(child, names)
        return found if found && !_empty_value?(found)
      end
    end
    nil
  end

  def self._find_list(value : JSON::Any, names : Array(String)) : Array(JSON::Any)
    if h = value.as_h?
      names.each do |name|
        candidate = h[name]?
        if arr = candidate.try(&.as_a?)
          return arr
        end
      end
      h.each_value do |child|
        found = _find_list(child, names)
        return found if !found.empty?
      end
    end
    [] of JSON::Any
  end

  def self._call_for(graph : Chronicle::GraphProjection, result_data : Hash(String, JSON::Any)) : Chronicle::GraphObject?
    call_id = result_data["call_id"]?.try(&.as_s?) || ""
    call = call_id.empty? ? nil : graph.get_object(call_id)
    call if call && call.type == "capability_call"
  end

  def self._exploration(graph : Chronicle::GraphProjection, key : String) : Chronicle::GraphObject?
    graph.objects(type: "integration_exploration").find do |obj|
      d = JSON.parse(obj.data)
      (d["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["exploration_key"]?.try(&.as_s?) == key &&
        d["status"]?.try(&.as_s?) != "completed"
    end
  end

  def self._labels(payload : JSON::Any) : Array(Hash(String, JSON::Any))
    rows = _find_list(payload, ["labels", "items"])
    result = [] of Hash(String, JSON::Any)
    rows.first(100).each do |row|
      h = row.as_h?
      next if h.nil?
      result << {
        "id"   => JSON::Any.new(h["id"]?.try(&.as_s?) || ""),
        "name" => JSON::Any.new((h["name"]?.try(&.as_s?) || h["label"]?.try(&.as_s?) || "")[0, 200]),
        "type" => JSON::Any.new(h["type"]?.try(&.as_s?) || "unknown"),
      }
    end
    result
  end

  def self._inventory(version : String, route : String) : Array(Hash(String, JSON::Any))
    rows = [
      {"gmail.profile.get", "R0", "GMAIL_GET_PROFILE", "none"},
      {"gmail.labels.list", "R0", "GMAIL_LIST_LABELS", "none"},
      {"gmail.messages.fetch", "R0", "GMAIL_FETCH_EMAILS", "none"},
      {"gmail.messages.get", "R0", "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", "none"},
      {"gmail.history.list", "R0", "GMAIL_LIST_HISTORY", "none"},
      {"gmail.drafts.create", "R2", "GMAIL_CREATE_EMAIL_DRAFT", "client_guard"},
      {"gmail.drafts.send", "R3", "GMAIL_SEND_DRAFT", "natural"},
    ]
    rows.map do |operation, action, provider_operation, idempotency|
      {
        "operation"                => JSON::Any.new(operation),
        "action_class"             => JSON::Any.new(action),
        "classification_source"    => JSON::Any.new("default"),
        "route"                    => JSON::Any.new(route),
        "provider_operation"       => route == "composio" ? JSON::Any.new(provider_operation) : JSON::Any.new(nil),
        "input_schema_fingerprint" => JSON::Any.new(nil),
        "idempotency"              => JSON::Any.new(idempotency),
        "metadata"                 => JSON::Any.new({"route_schema_version" => JSON::Any.new(version)}),
      }
    end
  end

  # ── gmail_exploration_projector ─────────────────────────────────────────

  # Turn the two exploration probe results into a service/account profile,
  # a source connection request, and a history watermark cursor.
  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_exploration_projector", on: ["object.created"], where: {"type" => "capability_result"}, creates: ["integration_profile", "aggregator_profile", "source_connection_request", "backfill_cursor"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream exploration projector profile/request/cursor branches
  def gmail_exploration_projector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    result_data = JSON.parse(event.payload).as_h["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless result_data["provider_name"]?.try(&.as_s?) == "gmail"
    call = _call_for(graph, result_data)
    return if call.nil?
    call_data = JSON.parse(call.data).as_h
    gmail_meta = (call_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["gmail"]?.try(&.as_h) || {} of String => JSON::Any
    return unless gmail_meta["kind"]?.try(&.as_s?) == "exploration"

    key = gmail_meta["exploration_key"]?.try(&.as_s?) || ""
    receipt = _exploration(graph, key)
    return if receipt.nil?

    envelope = _json(result_data["output_data"]?.try(&.as_s?) || "")
    receipt_data = JSON.parse(receipt.data).as_h
    metadata = (receipt_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
    results = (metadata["results"]?.try(&.as_h) || {} of String => JSON::Any).dup
    probe = gmail_meta["probe"]?.try(&.as_s?) || ""
    results[probe] = JSON::Any.new(envelope)
    metadata["results"] = JSON::Any.new(results)
    unless envelope["ok"]?.try(&.as_bool?) == true
      _merge_patch(graph, receipt.id, {"status" => JSON::Any.new("failed"), "metadata" => JSON::Any.new(metadata)})
      return
    end
    unless {"profile", "labels"}.all? { |probe_name| results.has_key?(probe_name) }
      _merge_patch(graph, receipt.id, {"status" => JSON::Any.new("partial"), "metadata" => JSON::Any.new(metadata)})
      return
    end

    profile_payload =
      begin
        _read_route_payload(results["profile"].as_h, settings)
      rescue ex
        metadata["error"] = JSON::Any.new("#{ex.class}: #{ex.message}"[0, 500])
        _merge_patch(graph, receipt.id, {"status" => JSON::Any.new("failed"), "metadata" => JSON::Any.new(metadata)})
        return
      end
    labels_payload =
      begin
        _read_route_payload(results["labels"].as_h, settings)
      rescue ex
        metadata["error"] = JSON::Any.new("#{ex.class}: #{ex.message}"[0, 500])
        _merge_patch(graph, receipt.id, {"status" => JSON::Any.new("failed"), "metadata" => JSON::Any.new(metadata)})
        return
      end

    email = (_find_key(profile_payload, ["emailAddress", "email_address", "email"]).try(&.as_s?) || "").strip.downcase
    if email.empty?
      _merge_patch(graph, receipt.id, {"status" => JSON::Any.new("failed"), "metadata" => JSON::Any.new(metadata)})
      return
    end
    account_id = gmail_meta["connected_account_id"]?.try(&.as_s?) || ""
    route = gmail_meta["route"]?.try(&.as_s?) || receipt_data["metadata"]?.try(&.as_h).try(&.["route"]?.try(&.as_s?)) || "composio"
    route_schema_version = results["profile"].as_h["route_schema_version"]?.try(&.as_s?) || settings.toolkit_version
    history_id = _find_key(profile_payload, ["historyId", "history_id"]).try(&.as_s?)
    label_rows = _labels(labels_payload)
    observed = JSON::Any.new({"profile" => profile_payload, "labels" => labels_payload})

    aggregator = nil.as(Chronicle::GraphObject?)
    if route == "composio"
      aggregator = ToolGateway.ensure_aggregator_profile_fn(
        graph,
        aggregator: "composio",
        user_ref: call_data["input_data"]?.try(&.as_h).try(&.["user_id"]?.try(&.as_s?)) || "",
        auth_state: "active",
        available_services: ["gmail"],
        enabled_services: ["gmail"],
        metadata: {"catalog_enumerated" => JSON::Any.new(false)},
      )
    end

    profile, _created = ToolGateway.record_integration_profile_fn(
      graph,
      service: "gmail",
      account_ref: email,
      account_display: email,
      routes: [
        {
          "path"                 => JSON::Any.new(route),
          "route_ref"            => JSON::Any.new("#{route}:#{account_id}"),
          "status"               => JSON::Any.new("active"),
          "connected_account_id" => JSON::Any.new(account_id),
          "schema_version"       => JSON::Any.new(route_schema_version),
          "metadata"             => JSON::Any.new(aggregator ? {"aggregator_profile_id" => JSON::Any.new(aggregator.id)} : {} of String => JSON::Any),
        } of String => JSON::Any,
      ],
      facets: ["record_store", "effector", "social_graph"],
      capability_inventory: _inventory(route_schema_version, route),
      data_topology: {
        "containers"      => JSON::Any.new(label_rows.map { |row| JSON::Any.new(row) }),
        "item_types"      => JSON::Any.new(["message", "thread", "draft"].map { |v| JSON::Any.new(v) }),
        "volume_estimate" => JSON::Any.new({
          "messages" => _find_key(profile_payload, ["messagesTotal", "messages_total"]) || JSON::Any.new(nil),
          "threads"  => _find_key(profile_payload, ["threadsTotal", "threads_total"]) || JSON::Any.new(nil),
        }),
        "history_watermark" => history_id ? JSON::Any.new(history_id) : JSON::Any.new(nil),
      },
      signal_map: [
        {
          "surface"            => JSON::Any.new("inbox"),
          "candidate_types"    => JSON::Any.new(["relationship", "task", "preference", "followup", "project"].map { |v| JSON::Any.new(v) }),
          "estimated_richness" => JSON::Any.new("high"),
          "confidence"         => JSON::Any.new(0.6),
          "provenance"         => JSON::Any.new([JSON::Any.new(receipt.id)]),
        } of String => JSON::Any,
      ],
      claims: [
        {
          "claim_key"             => JSON::Any.new("account.identity"),
          "value"                 => JSON::Any.new(email),
          "confidence"            => JSON::Any.new(1.0),
          "freshness"             => JSON::Any.new("current"),
          "provenance"            => JSON::Any.new((receipt_data["probe_call_ids"]?.try(&.as_a) || [] of JSON::Any).map { |v| JSON::Any.new(v.as_s) }),
          "classification_source" => JSON::Any.new("evidence"),
          "asserted_by"           => JSON::Any.new("gmail.integration_explorer"),
          "observed_at_event_id"  => JSON::Any.new(event.id),
          "metadata"              => JSON::Any.new({"structural_only" => JSON::Any.new(true)}),
        } of String => JSON::Any,
        {
          "claim_key"             => JSON::Any.new("mailbox.label_topology"),
          "value"                 => JSON::Any.new(label_rows.map { |row| JSON::Any.new(row) }),
          "confidence"            => JSON::Any.new(0.95),
          "freshness"             => JSON::Any.new("current"),
          "provenance"            => JSON::Any.new((receipt_data["probe_call_ids"]?.try(&.as_a) || [] of JSON::Any).map { |v| JSON::Any.new(v.as_s) }),
          "classification_source" => JSON::Any.new("evidence"),
          "asserted_by"           => JSON::Any.new("gmail.integration_explorer"),
          "observed_at_event_id"  => JSON::Any.new(event.id),
          "metadata"              => JSON::Any.new({"structural_only" => JSON::Any.new(true)}),
        } of String => JSON::Any,
        {
          "claim_key"             => JSON::Any.new("signal.inbox_richness"),
          "value"                 => JSON::Any.new("high"),
          "confidence"            => JSON::Any.new(0.6),
          "freshness"             => JSON::Any.new("current"),
          "provenance"            => JSON::Any.new([JSON::Any.new(receipt.id)]),
          "classification_source" => JSON::Any.new("evidence"),
          "asserted_by"           => JSON::Any.new("gmail.integration_explorer"),
          "observed_at_event_id"  => JSON::Any.new(event.id),
          "metadata"              => JSON::Any.new({"predicted" => JSON::Any.new(true)}),
        } of String => JSON::Any,
      ],
      health: {
        "drift_state"            => JSON::Any.new("current"),
        "shape_fingerprint"      => JSON::Any.new(ToolGateway.shape_fingerprint(observed)),
        "last_explored_event_id" => JSON::Any.new(event.id),
        "route_schema_version"   => JSON::Any.new(route_schema_version),
      },
      exploration_receipts: [receipt.id],
      metadata: {"scope_visibility" => JSON::Any.new("unknown"), "discovered_metadata_trusted" => JSON::Any.new(false)},
    )

    surface_id = ToolGateway.stable_integration_id("surface", "gmail", email, route)
    request_identity = ToolGateway.stable_integration_id("source_connection", surface_id, route)
    prior_request = graph.objects(type: "source_connection_request").find do |obj|
      JSON.parse(obj.data)["request_identity"]?.try(&.as_s?) == request_identity
    end
    if prior_request.nil?
      begin
        graph.add_object("source_connection_request", JSON.build do |json|
          json.object do
            json.field "request_identity", request_identity
            json.field "surface_id", surface_id
            json.field "category", "communication"
            json.field "provider" do
              json.object do
                json.field "service", "gmail"
                json.field "account_ref", email
                json.field "connected_account_id", account_id
                json.field "route", route
              end
            end
            json.field "path", route
            json.field "privacy_scope", "account"
            json.field "adapter", "gmail@0.1.0"
            json.field "acquisition_mode", "backfill"
            json.field "status", "proposed"
            json.field "surface_object_id", JSON::Any.new(nil)
            json.field "error", JSON::Any.new(nil)
            json.field "metadata" do
              json.object do
                json.field "integration_profile_id", profile.id
              end
            end
          end
        end, actor: "gmail.gmail_exploration_projector")
      rescue
      end
    end

    cursor_exists = graph.objects(type: "backfill_cursor").any? do |obj|
      JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == surface_id
    end
    if history_id && !cursor_exists
      begin
        graph.add_object("backfill_cursor", JSON.build do |json|
          json.object do
            json.field "source_surface_id", surface_id
            json.field "oldest_ingested_ref", JSON::Any.new(nil)
            json.field "newest_ingested_ref", JSON::Any.new(nil)
            json.field "watermark_ref", "history:#{history_id}"
            json.field "cursor_version", 1
          end
        end, actor: "gmail.gmail_exploration_projector")
      rescue
      end
    end

    _merge_patch(graph, receipt.id, {
      "account_ref"       => JSON::Any.new(email),
      "profile_id"        => JSON::Any.new(profile.id),
      "shape_fingerprint" => JSON::Any.new(ToolGateway.shape_fingerprint(observed)),
      "status"            => JSON::Any.new("completed"),
      "metadata"          => JSON::Any.new(metadata),
    })
    graph.add_relation(profile.id, receipt.id, "profile_explored_by", actor: "gmail.gmail_exploration_projector")
  end

  # ── message normalization ───────────────────────────────────────────────

  def self._header_map(message : Hash(String, JSON::Any)) : Hash(String, String)
    payload = message["payload"]?.try(&.as_h) || {} of String => JSON::Any
    headers = {} of String => String
    (payload["headers"]?.try(&.as_a) || [] of JSON::Any).each do |row|
      h = row.as_h?
      next if h.nil?
      name = h["name"]?.try(&.as_s?)
      if name && !name.empty?
        headers[name.downcase] = h["value"]?.try(&.as_s?) || ""
      end
    end
    {"from", "to", "cc", "bcc", "reply-to", "subject", "date", "message-id", "in-reply-to", "references", "list-id", "list-unsubscribe", "auto-submitted", "precedence"}.each do |key|
      direct = message[key]?.try(&.as_s?) || message[key.gsub("-", "_")]?.try(&.as_s?)
      if direct && !direct.empty? && !headers.has_key?(key)
        headers[key] = direct
      end
    end
    headers
  end

  def self._decode_body_data(value : String) : String
    padded = value.tr("-", "+").tr("_", "/")
    padded = padded + ("=" * (-padded.size % 4))
    bytes = Base64.decode(padded)
    String.new(bytes, "UTF-8", invalid: :replace)
  rescue
    ""
  end

  def self._body(message : Hash(String, JSON::Any)) : String
    {"messageText", "message_text", "body_text", "text", "body", "snippet"}.each do |key|
      value = message[key]?.try(&.as_s?)
      return value if value && !value.empty?
    end
    payload = message["payload"]?.try(&.as_h) || {} of String => JSON::Any
    body = payload["body"]?.try(&.as_h) || {} of String => JSON::Any
    if data = body["data"]?.try(&.as_s?)
      decoded = _decode_body_data(data)
      return decoded if !decoded.empty?
    end
    (payload["parts"]?.try(&.as_a) || [] of JSON::Any).each do |part|
      h = part.as_h?
      next if h.nil?
      candidate = _body(h)
      return candidate if !candidate.empty?
    end
    ""
  end

  def self._message_rows(payload : JSON::Any) : Array(Hash(String, JSON::Any))
    _find_list(payload, ["messages", "emails", "items"]).compact_map(&.as_h?)
  end

  def self._has_named_list(value : JSON::Any, names : Array(String)) : Bool
    return true if value.as_a?
    h = value.as_h?
    return false if h.nil?
    names.each do |name|
      return true if h[name]?.try(&.as_a?)
    end
    h.each_value.any? { |child| _has_named_list(child, names) }
  end

  def self._message_id(message : Hash(String, JSON::Any)) : String
    message["id"]?.try(&.as_s?) || message["message_id"]?.try(&.as_s?) || message["messageId"]?.try(&.as_s?) || ""
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _normalized_message header/body branches
  def self._normalized_message(message : Hash(String, JSON::Any), max_chars : Int32) : {String, Hash(String, JSON::Any)}
    headers = _header_map(message)
    body = _body(message)
    lines = [
      "Subject: #{headers["subject"]? || ""}",
      "From: #{headers["from"]? || ""}",
      "To: #{headers["to"]? || ""}",
      "Date: #{headers["date"]? || ""}",
    ]
    prefix = lines.join("\n") + "\n\n"
    content = (prefix + body)[0, max_chars]
    metadata = {
      "service"               => JSON::Any.new("gmail"),
      "interpretation_family" => JSON::Any.new("conversation"),
      "message_id"            => JSON::Any.new(_message_id(message)),
      "thread_id"             => JSON::Any.new(message["threadId"]?.try(&.as_s?) || message["thread_id"]?.try(&.as_s?) || ""),
      "history_id"            => JSON::Any.new(message["historyId"]?.try(&.as_s?) || message["history_id"]?.try(&.as_s?) || ""),
      "message_id_header"     => headers["message-id"]? ? JSON::Any.new(headers["message-id"]) : JSON::Any.new(nil),
      "from"                  => headers["from"]? ? JSON::Any.new(headers["from"]) : JSON::Any.new(nil),
      "to"                    => headers["to"]? ? JSON::Any.new(headers["to"]) : JSON::Any.new(nil),
      "cc"                    => headers["cc"]? ? JSON::Any.new(headers["cc"]) : JSON::Any.new(nil),
      "subject"               => headers["subject"]? ? JSON::Any.new(headers["subject"]) : JSON::Any.new(nil),
      "date"                  => headers["date"]? ? JSON::Any.new(headers["date"]) : JSON::Any.new(nil),
      "bcc"                   => headers["bcc"]? ? JSON::Any.new(headers["bcc"]) : JSON::Any.new(nil),
      "reply_to"              => headers["reply-to"]? ? JSON::Any.new(headers["reply-to"]) : JSON::Any.new(nil),
      "in_reply_to"           => headers["in-reply-to"]? ? JSON::Any.new(headers["in-reply-to"]) : JSON::Any.new(nil),
      "references"            => headers["references"]? ? JSON::Any.new(headers["references"]) : JSON::Any.new(nil),
      "list_id"               => headers["list-id"]? ? JSON::Any.new(headers["list-id"]) : JSON::Any.new(nil),
      "list_unsubscribe"      => headers["list-unsubscribe"]? ? JSON::Any.new(headers["list-unsubscribe"]) : JSON::Any.new(nil),
      "auto_submitted"        => headers["auto-submitted"]? ? JSON::Any.new(headers["auto-submitted"]) : JSON::Any.new(nil),
      "precedence"            => headers["precedence"]? ? JSON::Any.new(headers["precedence"]) : JSON::Any.new(nil),
      "body_offset"           => JSON::Any.new(prefix.size),
      "body_chars"            => JSON::Any.new(Math.max(0, Math.min(body.size, max_chars - prefix.size))),
      "labels"                => message["labelIds"]? || message["label_ids"]? || JSON::Any.new([] of JSON::Any),
      "injection_flags"       => JSON::Any.new(ToolGateway::Untrusted.scan_for_injection(content).map { |flag| JSON::Any.new(flag) }),
      "shape_fingerprint"     => JSON::Any.new(ToolGateway.shape_fingerprint(JSON::Any.new(message))),
      "truncated"             => JSON::Any.new(prefix.size + body.size > max_chars),
    }
    {content, metadata}
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _import_messages handoff branches
  def self._import_messages(graph : Chronicle::GraphProjection, messages : Array(Hash(String, JSON::Any)), run : Chronicle::GraphObject, settings : GmailSettings) : Array(String)
    imported = [] of String
    run_data = JSON.parse(run.data).as_h
    messages.each do |message|
      message_id = _message_id(message)
      next if message_id.empty?
      canonical = ToolGateway._canonical(JSON::Any.new(message))
      replay_ref, digest = ActivityNormalizer::Replay.store_replay_artifact(canonical, settings.artifact_store_dir)
      normalized, metadata = _normalized_message(message, settings.max_normalized_chars)
      acquired = graph.add_object("acquired_item", JSON.build do |json|
        json.object do
          json.field "source_surface_id", run_data["source_surface_id"]?.try(&.as_s?) || ""
          json.field "provider_item_id", message_id
          json.field "dedup_key", message_id
          json.field "source_ref", "gmail://#{run_data["connected_account_id"]?.try(&.as_s?) || ""}/messages/#{message_id}"
          json.field "source_hash", digest
          json.field "provider_time", metadata["date"]? || JSON::Any.new(nil)
          json.field "replay_mode", "artifact"
          json.field "replay_payload_ref", replay_ref
          json.field "replay_payload_hash", digest
          json.field "media_type", "message/rfc822+json"
          json.field "importer_id", "gmail"
          json.field "importer_version", "0.1.0"
        end
      end, actor: "gmail.gmail_sync_result_ingester")
      merged_meta = metadata.dup
      merged_meta["account_ref"] = JSON::Any.new(run_data["account_ref"]?.try(&.as_s?) || "")
      merged_meta["route"] = JSON::Any.new((run_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio")
      merged_meta["connected_account_id"] = JSON::Any.new(run_data["connected_account_id"]?.try(&.as_s?) || "")
      merged_meta["connector_run_id"] = JSON::Any.new(run.id)
      is_fixture = (run_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["is_fixture"]?.try(&.as_bool?) || false
      graph.add_object("acquired_content", JSON.build do |json|
        json.object do
          json.field "acquired_item_id", acquired.id
          json.field "normalized_content", normalized
          json.field "normalized_metadata", JSON::Any.new(merged_meta)
          json.field "source_category", "communication"
          json.field "connection_path", (run_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio"
          json.field "is_fixture", is_fixture
        end
      end, actor: "gmail.gmail_sync_result_ingester")
      imported << message_id
    end
    imported
  end

  def self._cursor(graph : Chronicle::GraphProjection, surface_id : String) : Chronicle::GraphObject?
    graph.objects(type: "backfill_cursor").find { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == surface_id }
  end

  def self._advance_cursor(graph : Chronicle::GraphProjection, cursor : Chronicle::GraphObject?, *, surface_id : String, message_ids : Array(String), watermark : String? = nil) : Chronicle::GraphObject
    updates = {} of String => JSON::Any
    if !message_ids.empty?
      cursor_data = cursor ? JSON.parse(cursor.data).as_h : {} of String => JSON::Any
      newest = cursor_data["newest_ingested_ref"]?.try(&.as_s?) || "message:#{message_ids.first}"
      updates["newest_ingested_ref"] = JSON::Any.new(newest)
      updates["oldest_ingested_ref"] = JSON::Any.new("message:#{message_ids.last}")
    end
    updates["watermark_ref"] = JSON::Any.new("history:#{watermark}") if watermark
    if cursor.nil?
      return graph.add_object("backfill_cursor", JSON.build do |json|
        json.object do
          json.field "source_surface_id", surface_id
          json.field "oldest_ingested_ref", updates["oldest_ingested_ref"]? || JSON::Any.new(nil)
          json.field "newest_ingested_ref", updates["newest_ingested_ref"]? || JSON::Any.new(nil)
          json.field "watermark_ref", updates["watermark_ref"]? || JSON::Any.new(nil)
          json.field "cursor_version", 1
        end
      end, actor: "gmail.gmail_sync_result_ingester")
    end
    if !updates.empty?
      _merge_patch(graph, cursor.id, updates)
    end
    graph.get_object(cursor.id) || cursor
  end

  def self._next_page(payload : JSON::Any) : String?
    value = _find_key(payload, ["nextPageToken", "next_page_token", "page_token"])
    value ? value.as_s? : nil
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _history_changes added/deleted bucket branches
  def self._history_changes(payload : JSON::Any) : {Array(String), Array(String), String?}
    history = _find_list(payload, ["history", "items"])
    ids = [] of String
    deleted = [] of String
    history.each do |row|
      h = row.as_h?
      next if h.nil?
      {"messagesAdded", "messages_added", "messages", "labelsAdded", "labels_added", "labelsRemoved", "labels_removed"}.each do |bucket|
        v = h[bucket]?
        next if v.nil?
        values = v.as_h? ? JSON::Any.new([v]) : v
        (values.as_a? || [] of JSON::Any).each do |raw_item|
          item = raw_item
          if (top = item.as_h?) && (nested = top["message"]?.try(&.as_h?))
            item = JSON::Any.new(nested)
          end
          h2 = item.as_h?
          next if h2.nil?
          mid = _message_id(h2)
          if !mid.empty? && !ids.includes?(mid)
            ids << mid
          end
        end
      end
      {"messagesDeleted", "messages_deleted", "deleted"}.each do |bucket|
        v = h[bucket]?
        next if v.nil?
        values = v.as_h? ? JSON::Any.new([v]) : v
        (values.as_a? || [] of JSON::Any).each do |raw_item|
          item = raw_item
          if (top = item.as_h?) && (nested = top["message"]?.try(&.as_h?))
            item = JSON::Any.new(nested)
          end
          h2 = item.as_h?
          next if h2.nil?
          mid = _message_id(h2)
          if !mid.empty? && !deleted.includes?(mid)
            deleted << mid
          end
        end
      end
    end
    watermark = _find_key(payload, ["historyId", "history_id"]).try(&.as_s?)
    {ids, deleted, watermark}
  end

  def self._classify_provider_failure(message : String) : String
    lowered = message.downcase
    if lowered.includes?("429") || lowered.includes?("rate limit") || lowered.includes?("rate_limit")
      return "rate_limited"
    end
    if lowered.includes?("401") || lowered.includes?("403") || lowered.includes?("auth") || lowered.includes?("credential")
      return "auth_expired"
    end
    if lowered.includes?("history") && ["invalid", "expired", "404", "too old"].any? { |word| lowered.includes?(word) }
      return "cursor_invalid"
    end
    "provider_failed"
  end

  def self._is_provider_not_found(message : String) : Bool
    lowered = message.downcase
    lowered.includes?("404") || lowered.includes?("not found") || lowered.includes?("notfound")
  end

  def self._record_deletion_tombstone(graph : Chronicle::GraphProjection, reader : Chronicle::GraphProjection, run : Chronicle::GraphObject, *, message_id : String, watermark : String?, observation : String) : Bool
    run_data = JSON.parse(run.data).as_h
    identity = ToolGateway.stable_integration_id("gmail_tombstone", run_data["source_surface_id"]?.try(&.as_s?) || "", message_id, watermark || "")
    existing = reader.objects(type: "evidence_invalidation_request").find { |obj| JSON.parse(obj.data)["request_identity"]?.try(&.as_s?) == identity }
    return false if existing
    begin
      graph.add_object("evidence_invalidation_request", JSON.build do |json|
        json.object do
          json.field "request_identity", identity
          json.field "source_surface_id", run_data["source_surface_id"]?.try(&.as_s?) || ""
          json.field "provider_item_id", message_id
          json.field "evidence_identity", JSON::Any.new(nil)
          json.field "reason", "provider_deleted"
          json.field "status", "proposed"
          json.field "invalidated_evidence_ids", [] of JSON::Any
          json.field "error", JSON::Any.new(nil)
          json.field "metadata" do
            json.object do
              json.field "history_id", watermark ? JSON::Any.new(watermark) : JSON::Any.new(nil)
              json.field "gmail_sync_run_id", run.id
              json.field "observation", observation
            end
          end
        end
      end, actor: "gmail.gmail_sync_result_ingester")
    rescue
    end
    true
  end

  def self._settle_missing_history_message(graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, run : Chronicle::GraphObject, *, message_id : String) : Nil
    run_data = JSON.parse(run.data).as_h
    watermark = run_data["latest_history_id"]?.try(&.as_s?)
    created = _record_deletion_tombstone(graph, graph, run, message_id: message_id, watermark: watermark, observation: "message_lookup_not_found")
    missing = (run_data["missing_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    missing << message_id unless missing.includes?(message_id)
    deleted = (run_data["deleted_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    deleted << message_id unless deleted.includes?(message_id)
    completed = (run_data["completed_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    pending = (run_data["pending_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    settled = (completed.to_set + missing.to_set)
    updates = {
      "missing_message_ids" => JSON::Any.new(missing.map { |id| JSON::Any.new(id) }),
      "deleted_message_ids" => JSON::Any.new(deleted.map { |id| JSON::Any.new(id) }),
      "tombstones_recorded" => JSON::Any.new((run_data["tombstones_recorded"]?.try(&.as_i?) || 0) + (created ? 1 : 0)),
    }
    if settled.superset_of?(pending.to_set)
      _advance_cursor(
        graph,
        _cursor(graph, run_data["source_surface_id"]?.try(&.as_s?) || ""),
        surface_id: run_data["source_surface_id"]?.try(&.as_s?) || "",
        message_ids: completed,
        watermark: watermark,
      )
      updates["status"] = JSON::Any.new("completed")
    end
    _merge_patch(graph, run.id, updates)
  end

  def self._active_profile(graph : Chronicle::GraphProjection, account_ref : String) : Chronicle::GraphObject?
    graph.objects(type: "integration_profile").find do |obj|
      d = JSON.parse(obj.data)
      d["service"]?.try(&.as_s?) == "gmail" && d["account_ref"]?.try(&.as_s?) == account_ref && d["status"]?.try(&.as_s?) == "active"
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _mark_profile_drift stale-record branches
  def self._mark_profile_drift(graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, run : Chronicle::GraphObject, *, reason : String, call_id : String, observed_shape : JSON::Any? = nil) : Chronicle::GraphObject?
    profile = _active_profile(graph, JSON.parse(run.data)["account_ref"]?.try(&.as_s?) || "")
    return nil if profile.nil?
    data = JSON.parse(profile.data).as_h
    health = (data["health"]?.try(&.as_h) || {} of String => JSON::Any).dup
    health["drift_state"] = JSON::Any.new("stale")
    health["drift_reason"] = JSON::Any.new(reason)
    health["drift_call_id"] = JSON::Any.new(call_id)
    if observed_shape
      health["unexpected_shape_fingerprint"] = JSON::Any.new(ToolGateway.shape_fingerprint(observed_shape))
    end
    claims = (data["claims"]?.try(&.as_a) || [] of JSON::Any).map do |claim|
      c = claim.as_h.dup
      c["freshness"] = JSON::Any.new("stale")
      c
    end
    stale, _created = ToolGateway.record_integration_profile_fn(
      graph,
      service: data["service"]?.try(&.as_s?) || "",
      account_ref: data["account_ref"]?.try(&.as_s?) || "",
      account_display: data["account_display"]?.try(&.as_s?),
      routes: (data["routes"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h),
      scopes_granted: (data["scopes_granted"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      scopes_available: (data["scopes_available"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      facets: (data["facets"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      capability_inventory: (data["capability_inventory"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h),
      data_topology: data["data_topology"]?.try(&.as_h) || {} of String => JSON::Any,
      signal_map: (data["signal_map"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h),
      claims: claims,
      health: health,
      exploration_receipts: (data["exploration_receipts"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      metadata: data["metadata"]?.try(&.as_h) || {} of String => JSON::Any,
      profile_status: "stale",
    )
    stale
  end

  def self._fail_sync(graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, run : Chronicle::GraphObject, *, code : String, message : String, call_id : String, payload : JSON::Any? = nil) : Nil
    run_data = JSON.parse(run.data).as_h
    recoverable = code.in?({"rate_limited", "cursor_invalid", "unexpected_shape"})
    begin
      ActivityNormalizer.record_failure(
        graph,
        stage: "acquisition",
        error_code: "gmail.#{code}",
        message: message,
        source_surface_id: run_data["source_surface_id"]?.try(&.as_s?),
        source_ref: "gmail://#{run_data["connected_account_id"]?.try(&.as_s?) || ""}/sync/#{run.id}",
        importer_id: "gmail",
        importer_version: "0.1.0",
        recoverable: recoverable,
        metadata: {"run_id" => JSON::Any.new(run.id), "call_id" => JSON::Any.new(call_id)},
      )
    rescue
    end
    metadata = (run_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
    metadata["reanchor_required"] = JSON::Any.new(true) if code == "cursor_invalid"
    _merge_patch(graph, run.id, {
      "status"     => JSON::Any.new("failed"),
      "error_code" => JSON::Any.new(code),
      "error"      => JSON::Any.new(message[0, 500]),
      "metadata"   => JSON::Any.new(metadata),
    })
    if code.in?({"auth_expired", "cursor_invalid", "unexpected_shape"})
      _mark_profile_drift(graph, ctx, run, reason: code, call_id: call_id, observed_shape: payload)
    end
  end

  # ── gmail_sync_result_ingester ──────────────────────────────────────────

  # Turn recorded sync route results into acquired items + cursor state.
  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_sync_result_ingester", on: ["object.created"], where: {"type" => "capability_result"}, creates: ["acquired_item", "acquired_content", "backfill_cursor", "capability_call", "evidence_invalidation_request", "ingestion_failure", "integration_profile"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream sync ingester backfill/history/message branches
  def gmail_sync_result_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    result_data = JSON.parse(event.payload).as_h["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless result_data["provider_name"]?.try(&.as_s?) == "gmail"
    call = _call_for(graph, result_data)
    return if call.nil?
    call_data = JSON.parse(call.data).as_h
    meta = (call_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["gmail"]?.try(&.as_h) || {} of String => JSON::Any
    kind = meta["kind"]?.try(&.as_s?)
    return unless kind.in?({"backfill", "history", "history_message"})

    run = graph.get_object(meta["run_id"]?.try(&.as_s?) || "")
    if run.nil? || run.type != "gmail_sync_run" || !JSON.parse(run.data)["status"]?.try(&.as_s?).in?({"running", "partial"})
      return
    end
    run_data = JSON.parse(run.data).as_h

    envelope = _json(result_data["output_data"]?.try(&.as_s?) || "")
    unless envelope["ok"]?.try(&.as_bool?) == true
      message = envelope["error"]?.try(&.as_s?) || "Gmail call failed"
      if kind == "history_message" && _is_provider_not_found(message)
        message_id = meta["message_id"]?.try(&.as_s?) || ""
        if !message_id.empty?
          _settle_missing_history_message(graph, ctx, run, message_id: message_id)
          return
        end
      end
      _fail_sync(graph, ctx, run, code: _classify_provider_failure(message), message: message, call_id: call.id)
      return
    end

    payload =
      begin
        _read_route_payload(envelope, settings)
      rescue ex
        _fail_sync(graph, ctx, run, code: "unexpected_shape", message: "Gmail replay artifact could not be read: #{ex.class}: #{ex.message}", call_id: call.id)
        return
      end

    if kind == "backfill"
      unless _has_named_list(payload, ["messages", "emails", "items"])
        _fail_sync(graph, ctx, run, code: "unexpected_shape", message: "Gmail message page omitted a recognized message collection", call_id: call.id, payload: payload)
        return
      end
      remaining = Math.max(0, (run_data["max_messages"]?.try(&.as_i?) || 0) - (run_data["messages_imported"]?.try(&.as_i?) || 0))
      rows = _message_rows(payload).first(remaining)
      imported = _import_messages(graph, rows, run, settings)
      _advance_cursor(graph, _cursor(graph, run_data["source_surface_id"]?.try(&.as_s?) || ""), surface_id: run_data["source_surface_id"]?.try(&.as_s?) || "", message_ids: imported)
      pages = (run_data["pages_completed"]?.try(&.as_i?) || 0) + 1
      count = (run_data["messages_imported"]?.try(&.as_i?) || 0) + imported.size
      token = _next_page(payload)
      bound_hit = count >= (run_data["max_messages"]?.try(&.as_i?) || 0) || pages >= (run_data["max_pages"]?.try(&.as_i?) || 0)
      status = (token && bound_hit) ? "partial" : (token ? "running" : "completed")
      _merge_patch(graph, run.id, {
        "pages_completed"   => JSON::Any.new(pages),
        "messages_imported" => JSON::Any.new(count),
        "next_page_token"   => token ? JSON::Any.new(token) : JSON::Any.new(nil),
        "status"            => JSON::Any.new(status),
      })
      if token && !bound_hit
        if fresh_run = graph.get_object(run.id)
          propose_gmail_page_fn(graph, fresh_run, page_token: token)
        end
      end
      return
    end

    if kind == "history"
      unless _has_named_list(payload, ["history", "items"])
        _fail_sync(graph, ctx, run, code: "unexpected_shape", message: "Gmail history page omitted a recognized history collection", call_id: call.id, payload: payload)
        return
      end
      message_ids, deleted_ids, watermark = _history_changes(payload)
      message_ids = message_ids.first(run_data["max_messages"]?.try(&.as_i?) || 0)
      tombstones = 0
      deleted_ids.first(run_data["max_messages"]?.try(&.as_i?) || 0).each do |deleted_id|
        tombstones += (_record_deletion_tombstone(graph, graph, run, message_id: deleted_id, watermark: watermark, observation: "history_deleted") ? 1 : 0)
      end
      calls = (run_data["call_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
      message_ids.each do |added_id|
        fetch = _capability_call(
          graph,
          operation: "messages.get", action_class: "R0", risk_class: "low",
          input_data: {
            "user_id"              => JSON::Any.new(run_data["user_id"]?.try(&.as_s?) || ""),
            "connected_account_id" => JSON::Any.new(run_data["connected_account_id"]?.try(&.as_s?) || ""),
            "message_id"           => JSON::Any.new(added_id),
          },
          metadata: {"kind" => JSON::Any.new("history_message"), "run_id" => JSON::Any.new(run.id), "message_id" => JSON::Any.new(added_id)},
          proposed_by: "gmail.poll",
          route: (run_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio",
        )
        graph.add_relation(run.id, fetch.id, "gmail_sync_call", actor: "gmail.gmail_sync_result_ingester")
        calls << fetch.id
      end
      updates = {
        "pending_message_ids" => JSON::Any.new(message_ids.map { |id| JSON::Any.new(id) }),
        "latest_history_id"   => watermark ? JSON::Any.new(watermark) : JSON::Any.new(nil),
        "deleted_message_ids" => JSON::Any.new(deleted_ids.map { |id| JSON::Any.new(id) }),
        "tombstones_recorded" => JSON::Any.new((run_data["tombstones_recorded"]?.try(&.as_i?) || 0) + tombstones),
        "call_ids"            => JSON::Any.new(calls.map { |id| JSON::Any.new(id) }),
        "pages_completed"     => JSON::Any.new(1),
      }
      if message_ids.empty?
        _advance_cursor(graph, _cursor(graph, run_data["source_surface_id"]?.try(&.as_s?) || ""), surface_id: run_data["source_surface_id"]?.try(&.as_s?) || "", message_ids: [] of String, watermark: watermark)
        updates["status"] = JSON::Any.new("completed")
      end
      _merge_patch(graph, run.id, updates)
      return
    end

    rows = _message_rows(payload)
    if rows.empty?
      unwrapped = _unwrap(payload)
      if uh = unwrapped.as_h?
        mid = _message_id(uh)
        rows = [uh] if !mid.empty?
      end
    end
    if rows.empty?
      _fail_sync(graph, ctx, run, code: "unexpected_shape", message: "Gmail message lookup omitted the requested message", call_id: call.id, payload: payload)
      return
    end
    imported = _import_messages(graph, rows.first(1), run, settings)
    completed = (run_data["completed_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    imported.each { |imported_id| completed << imported_id unless completed.includes?(imported_id) }
    pending = (run_data["pending_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    missing = (run_data["missing_message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    done = (completed.to_set + missing.to_set).superset_of?(pending.to_set)
    updates = {
      "completed_message_ids" => JSON::Any.new(completed.map { |id| JSON::Any.new(id) }),
      "messages_imported"     => JSON::Any.new(completed.size),
    }
    if done
      _advance_cursor(
        graph, _cursor(graph, run_data["source_surface_id"]?.try(&.as_s?) || ""),
        surface_id: run_data["source_surface_id"]?.try(&.as_s?) || "",
        message_ids: completed,
        watermark: run_data["latest_history_id"]?.try(&.as_s?),
      )
      updates["status"] = JSON::Any.new("completed")
    end
    _merge_patch(graph, run.id, updates)
  end

  # ── gmail_draft_result_projector ────────────────────────────────────────

  # Commit only approved provider draft effects back to the local draft.
  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_draft_result_projector", on: ["object.created"], where: {"type" => "capability_result"}, creates: [] of String)]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream draft projector create/send branches
  def gmail_draft_result_projector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    result_data = JSON.parse(event.payload).as_h["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless result_data["provider_name"]?.try(&.as_s?) == "gmail"
    call = _call_for(graph, result_data)
    return if call.nil?
    call_data = JSON.parse(call.data).as_h
    meta = (call_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["gmail"]?.try(&.as_h) || {} of String => JSON::Any
    kind = meta["kind"]?.try(&.as_s?)
    return unless kind.in?({"draft_create", "draft_send"})

    draft = graph.get_object(meta["draft_id"]?.try(&.as_s?) || "")
    return if draft.nil? || draft.type != "gmail_draft_candidate"
    draft_data = JSON.parse(draft.data).as_h

    envelope = _json(result_data["output_data"]?.try(&.as_s?) || "")
    unless envelope["ok"]?.try(&.as_bool?) == true
      metadata = (draft_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
      metadata["last_error"] = JSON::Any.new((envelope["error"]?.try(&.as_s?) || "Gmail draft effect failed")[0, 500])
      _merge_patch(graph, draft.id, {"status" => JSON::Any.new("rejected"), "metadata" => JSON::Any.new(metadata)})
      return
    end
    if kind == "draft_create"
      payload =
        begin
          _read_route_payload(envelope, settings)
        rescue ex
          metadata = (draft_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
          metadata["last_error"] = JSON::Any.new("Gmail draft replay artifact could not be read: #{ex.class}: #{ex.message}"[0, 500])
          _merge_patch(graph, draft.id, {"status" => JSON::Any.new("rejected"), "metadata" => JSON::Any.new(metadata)})
          return
        end
      provider_id = _find_key(_unwrap(payload), ["draftId", "draft_id", "id"]).try(&.as_s?) || ""
      if provider_id.empty?
        metadata = (draft_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
        metadata["last_error"] = JSON::Any.new("Gmail create-draft response omitted a provider draft id")
        _merge_patch(graph, draft.id, {"status" => JSON::Any.new("rejected"), "metadata" => JSON::Any.new(metadata)})
        return
      end
      _merge_patch(graph, draft.id, {"status" => JSON::Any.new("synced"), "provider_draft_id" => JSON::Any.new(provider_id)})
      return
    end
    _merge_patch(graph, draft.id, {"status" => JSON::Any.new("sent")})
  end

  # ── control-plane behaviors ─────────────────────────────────────────────

  # Keep the neutral control plane aligned with authoritative Gmail runs.
  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_control_plane_adapter", on: ["patch.applied"], creates: ["connector_surface_binding", "connector_run_observation", "connector_learning_delta", "connector_native_view"])]
  def gmail_control_plane_adapter(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    object_id = JSON.parse(event.payload).as_h["target"]?.try(&.as_s?) || ""
    obj = object_id.empty? ? nil : graph.get_object(object_id)
    return if obj.nil? || obj.type != "gmail_sync_run"

    # chronicle's patch.applied payload carries no status diff, so the
    # failed→running attempt detection is unavailable (attempt defaults false).
    adapt_gmail_run_fn(graph, obj, source_event_id: event.id, attempt: false, reader: graph)
  end

  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_control_plane_run_created", on: ["object.created"], where: {"type" => "gmail_sync_run"}, creates: ["connector_surface_binding", "connector_run_observation", "connector_learning_delta", "connector_native_view"])]
  def gmail_control_plane_run_created(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    run = graph.get_object(JSON.parse(event.payload).as_h["id"]?.try(&.as_s?) || "")
    return if run.nil?
    adapt_gmail_run_fn(graph, run, source_event_id: event.id, attempt: true, reader: graph)
  end

  # Materialize once the run's evidence batch exists, before extraction.
  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_conversation_family_ready", on: ["object.created"], where: {"type" => "activity_evidence", "data.normalized_metadata.service" => "gmail"}, creates: [] of String)]
  def gmail_conversation_family_ready(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    data = JSON.parse(event.payload).as_h["data"]?.try(&.as_h) || {} of String => JSON::Any
    run_id = gmail_run_id_for_object(graph, "activity_evidence", data)
    run = run_id ? graph.objects(type: "gmail_sync_run").find { |obj| obj.id == run_id } : nil
    return if run.nil?
    run_data = JSON.parse(run.data).as_h
    return unless run_data["status"]?.try(&.as_s?).in?({"completed", "partial"})
    expected = run_data["messages_imported"]?.try(&.as_i?) || 0
    present = graph.objects(type: "activity_evidence").select do |obj|
      (JSON.parse(obj.data)["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any)["connector_run_id"]?.try(&.as_s?) == run.id
    end
    return if expected <= 0 || present.size < expected
    _emit_event(graph, "gmail.conversation_batch_requested", {"run_id" => JSON::Any.new(run.id), "offset" => JSON::Any.new(0), "expected" => JSON::Any.new(expected), "batch_size" => JSON::Any.new(25)}, caused_by: nil, actor: "gmail.gmail_conversation_family_ready")
  end

  # Project one bounded family batch, then schedule the continuation.
  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_conversation_batch_projector", on: ["gmail.conversation_batch_requested"], creates: ["conversation_thread", "conversation_message", "conversation_participant", "conversation_interpretation_run", "selection_extraction_request", "entity_mention"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream batch projector continuation branches
  def gmail_conversation_batch_projector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    run_id = payload["run_id"]?.try(&.as_s?) || ""
    run = graph.objects(type: "gmail_sync_run").find { |obj| obj.id == run_id }
    return if run.nil?
    offset = Math.max(0, payload["offset"]?.try(&.as_i?) || 0)
    expected = Math.max(0, payload["expected"]?.try(&.as_i?) || 0)
    batch_size = Math.max(1, Math.min(payload["batch_size"]?.try(&.as_i?) || 25, 25))
    native_data, summary = materialize_gmail_run_fn(graph, run, reader: graph, offset: offset, max_items: batch_size)
    processed = summary["messages"]?.try(&.as_i?) || 0
    next_offset = offset + processed
    if processed > 0 && next_offset < expected
      _emit_event(graph, "gmail.conversation_batch_requested", {
        "run_id"     => JSON::Any.new(run.id),
        "offset"     => JSON::Any.new(next_offset),
        "expected"   => JSON::Any.new(expected),
        "batch_size" => JSON::Any.new(batch_size),
      }, caused_by: nil, actor: "gmail.gmail_conversation_batch_projector")
      return
    end
    if next_offset >= expected
      existing_model_runs = graph.objects(type: "conversation_interpretation_run").select do |obj|
        d = JSON.parse(obj.data)
        (d["refs"]?.try(&.as_a) || [] of JSON::Any).any? { |ref| ref.as_s? == run.id } && !d["semantic_request_id"]?.try(&.as_s?).nil?
      end
      adapt_gmail_run_fn(
        graph,
        run,
        source_event_id: nil,
        attempt: false,
        reader: graph,
        native_data: native_data,
        learning_settled_override: (summary["semantic_requests_created"]?.try(&.as_i?) || 0) == 0 &&
                                   existing_model_runs.all? { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "completed" },
      )
    end
  end

  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_control_plane_learning_settled", on: ["object.created"], where: {"type" => "extraction_coverage"}, creates: ["connector_surface_binding", "connector_run_observation", "connector_learning_delta", "connector_native_view", "conversation_thread", "conversation_message", "conversation_participant", "conversation_interpretation_run", "selection_extraction_request", "entity_mention"])]
  def gmail_control_plane_learning_settled(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    data = JSON.parse(event.payload).as_h["data"]?.try(&.as_h) || {} of String => JSON::Any
    run_id = gmail_run_id_for_object(graph, "extraction_coverage", data)
    run = run_id ? graph.get_object(run_id) : nil
    return if run.nil? || !gmail_learning_settled(graph, run)
    native_data = Communication.project_conversation_native_fn(graph, JSON.parse(run.data)["source_surface_id"]?.try(&.as_s?) || "")
    adapt_gmail_run_fn(graph, run, source_event_id: nil, attempt: false, reader: graph, native_data: native_data)
  end

  @[Chronicle::Packs::Annotations::Behavior(name: "gmail_control_plane_failure", on: ["object.created"], where: {"type" => "ingestion_failure"}, creates: ["connector_surface_binding", "connector_run_observation", "connector_learning_delta", "connector_native_view", "conversation_thread", "conversation_message", "conversation_participant", "conversation_interpretation_run", "selection_extraction_request", "entity_mention"])]
  def gmail_control_plane_failure(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : GmailSettings) : Nil
    data = JSON.parse(event.payload).as_h["data"]?.try(&.as_h) || {} of String => JSON::Any
    run_id = gmail_run_id_for_object(graph, "ingestion_failure", data)
    run = run_id ? graph.get_object(run_id) : nil
    return if run.nil?
    adapt_gmail_run_fn(graph, run, source_event_id: nil, attempt: false, reader: graph)
  end
end

require "json"
require "time"

module Chronicle::Packs::IdentityAuth
  # Identity/Auth behaviors. Ported from upstream
  # packs/identity_auth/behaviors.py.
  #
  # 1. principal_resolver — on source.created, resolves sender_ref to a
  #    Principal (dedup by normalized sender_ref; owner vs default role).
  # 2. comm_message_principal_resolver — same, on comm_message.created.
  # 3. auth_context_builder — on principal.created, creates an AuthContext.
  # 4. permission_checker — on action.created (status=proposed), rejects
  #    actions the proposing principal's role does not allow.
  # 5. principal_entity_linker — soft Entity-pack integration (no-op here;
  #    the entity pack is not ported yet).

  # ------------------------------------------------------------------ registry

  # Normalized sender_ref → principal_id dedup registry, shared by both
  # resolver behaviors and the register_principal tool.
  class_property principal_registry = {} of String => String

  # ISO 8601 UTC now (upstream `datetime.now(timezone.utc).isoformat()`).
  def self._utc_now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  def self._normalize_identifier(identifier : String) : String
    identifier.strip.downcase
  end

  def self.clear_principal_registry : Nil
    self.principal_registry = {} of String => String
  end

  # True when any principals are known to the in-process registry — the
  # 'is verification possible?' check used by admission/approval logic.
  def self.principals_registered : Bool
    !principal_registry.empty?
  end

  # Repopulate the dedup registry from existing principals in `graph`.
  # After a runtime resume (replay without behaviors), the registry would
  # otherwise be empty and already-known senders would create duplicates.
  # Returns the number of principals indexed.
  def self.rebuild_principal_registry(graph : Chronicle::GraphProjection) : Int32
    self.principal_registry = {} of String => String
    count = 0
    graph.objects(type: "principal").each do |obj|
      data = JSON.parse(obj.data)
      ref = data["identifiers"]?.try(&.["ref"]?.try(&.as_s?))
      next if ref.nil? || ref.empty?

      principal_registry[_normalize_identifier(ref)] = obj.id
      count += 1
    end
    count
  end

  # Behavior-safe principal lookup by sender_ref (dedup registry +
  # graph.get_object — never a graph.objects scan). Returns the principal
  # data plus id, or nil for a sender never seen.
  def self.resolve_known_principal(graph : Chronicle::GraphProjection, sender_ref : String) : Hash(String, JSON::Any)?
    pid = principal_registry[_normalize_identifier(sender_ref)]?
    return nil if pid.nil?

    obj = graph.get_object(pid)
    return nil if obj.nil?

    {"id" => JSON::Any.new(pid)}.merge(JSON.parse(obj.data).as_h)
  end

  # ------------------------------------------------------------------ helpers

  # Top-level merge for chronicle's replace-semantics patch_object
  # (upstream patch merges; here the caller passes the full merged data).
  def self._merge_patch(current : String, changes : Hash(String, JSON::Any)) : String
    data = JSON.parse(current).as_h
    changes.each { |key, value| data[key] = value }
    data.to_json
  end

  def self._matches_owner_identifiers(sender_ref : String, owner_identifiers : Array(String)) : Bool
    norm = _normalize_identifier(sender_ref)
    owner_identifiers.any? { |identifier| _normalize_identifier(identifier) == norm }
  end

  def self._extract_display_name(sender_ref : String) : String
    if sender_ref.includes?('@')
      sender_ref.split('@').first.gsub('.', ' ').gsub('_', ' ').split(' ').map(&.capitalize).join(' ')
    else
      sender_ref
    end
  end

  # Core resolution logic shared by the source and comm_message paths.
  # Returns the principal_id (existing or newly created) and creates the
  # resolves_to relation.
  def self._resolve_principal(
    sender_ref : String,
    channel : String,
    frame_id : String?,
    source_id : String,
    graph : Chronicle::GraphProjection,
    settings : IdentitySettings,
  ) : String?
    now = _utc_now_iso
    norm_ref = _normalize_identifier(sender_ref)

    # Dedup: reuse an existing principal for the same normalized sender.
    if settings.auto_deduplicate_principals? && (existing_id = principal_registry[norm_ref]?)
      begin
        if existing = graph.get_object(existing_id)
          current = JSON.parse(existing.data)
          seen = current["seen_count"]?.try(&.as_i) || 1
          graph.patch_object(existing_id, _merge_patch(existing.data, {
            "last_seen_at" => JSON::Any.new(now),
            "seen_count"   => JSON::Any.new(seen + 1),
          }))
        end
      rescue
      end

      begin
        graph.add_relation(source_id, existing_id, "resolves_to")
      rescue
      end
      return existing_id
    end

    # New sender: determine role and confidence.
    if _matches_owner_identifiers(sender_ref, settings.owner_identifiers)
      role = "owner"
      confidence = settings.owner_auth_confidence
      name = sender_ref
    else
      role = settings.default_external_role
      confidence = settings.default_auth_confidence
      name = _extract_display_name(sender_ref)
    end

    identifiers = {"ref" => JSON::Any.new(sender_ref)}
    identifiers["email"] = JSON::Any.new(sender_ref) if sender_ref.includes?('@')

    data = JSON.build do |json|
      json.object do
        json.field "name", name
        json.field "role", role
        json.field "auth_confidence", confidence
        json.field "identifiers", identifiers
        json.field "channel", channel
        json.field "frame_id", frame_id if frame_id
        json.field "last_seen_at", now
        json.field "seen_count", 1
        json.field "metadata", {"resolved_from_source" => JSON::Any.new(source_id)}
      end
    end
    principal = graph.add_object("principal", data)

    principal_registry[norm_ref] = principal.id if settings.auto_deduplicate_principals?

    begin
      graph.add_relation(source_id, principal.id, "resolves_to")
    rescue
    end
    principal.id
  end

  # ------------------------------------------------------------------ behaviors

  # Resolve a source's sender_ref to a Principal.
  @[Chronicle::Packs::Annotations::Behavior(name: "principal_resolver", on: ["object.created"], where: {"type" => "source"}, creates: ["principal"])]
  def principal_resolver(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : IdentitySettings) : Nil
    payload = JSON.parse(event.payload)
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?

    data = payload["data"]?
    sender_ref = data.try(&.["sender_ref"]?.try(&.as_s?)) || ""
    return if sender_ref.empty?

    channel = data.try(&.["channel"]?.try(&.as_s?)) || "unknown"
    frame_id = data.try(&.["frame_id"]?.try(&.as_s?))
    _resolve_principal(sender_ref, channel, frame_id, source_id, graph, settings)
  end

  # Resolve a CommMessage's sender to a Principal (Communication Pack).
  @[Chronicle::Packs::Annotations::Behavior(name: "comm_message_principal_resolver", on: ["object.created"], where: {"type" => "comm_message"}, creates: ["principal"])]
  def comm_message_principal_resolver(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : IdentitySettings) : Nil
    payload = JSON.parse(event.payload)
    msg_id = payload["id"]?.try(&.as_s?)
    return if msg_id.nil?

    data = payload["data"]?
    sender_ref = data.try(&.["sender_ref"]?.try(&.as_s?)) || data.try(&.["from_address"]?.try(&.as_s?)) || ""
    return if sender_ref.empty?

    channel = data.try(&.["channel"]?.try(&.as_s?)) || "unknown"
    frame_id = data.try(&.["frame_id"]?.try(&.as_s?))
    _resolve_principal(sender_ref, channel, frame_id, msg_id, graph, settings)
  end

  # Create an AuthContext snapshotting the principal's role.
  @[Chronicle::Packs::Annotations::Behavior(name: "auth_context_builder", on: ["object.created"], where: {"type" => "principal"}, creates: ["auth_context"])]
  def auth_context_builder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : IdentitySettings) : Nil
    return if !settings.create_auth_context?

    payload = JSON.parse(event.payload)
    principal_id = payload["id"]?.try(&.as_s?)
    return if principal_id.nil?

    data = payload["data"]?
    role = data.try(&.["role"]?.try(&.as_s?)) || "unknown"
    channel = data.try(&.["channel"]?.try(&.as_s?)) || "unknown"
    frame_id = data.try(&.["frame_id"]?.try(&.as_s?))
    now = _utc_now_iso

    auth_data = JSON.build do |json|
      json.object do
        json.field "principal_id", principal_id
        json.field "principal_role", role
        json.field "channel", channel
        json.field "frame_id", frame_id if frame_id
        json.field "verified_at", now if role == "owner"
        json.field "metadata", {"created_by" => JSON::Any.new("auth_context_builder")}
      end
    end
    auth_ctx = graph.add_object("auth_context", auth_data)

    begin
      graph.add_relation(principal_id, auth_ctx.id, "authenticated_by")
    rescue
    end
  end

  # Soft Entity-pack integration: links a resolved Principal to an existing
  # Entity. The entity pack is not ported yet, so this is a no-op (upstream
  # also no-ops when the entity pack is absent).
  @[Chronicle::Packs::Annotations::Behavior(name: "principal_entity_linker", on: ["object.created"], where: {"type" => "principal"})]
  def principal_entity_linker(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : IdentitySettings) : Nil
  end

  # Check that the proposing principal's role allows the action. Patches
  # the action to 'rejected' when denied; otherwise marks it checked.
  @[Chronicle::Packs::Annotations::Behavior(name: "permission_checker", on: ["object.created"], where: {"type" => "action"})]
  def permission_checker(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : IdentitySettings) : Nil
    return if !settings.check_permissions_on_proposed_actions?

    context = _permission_context(event, graph)
    return if context.nil?

    action_id = context[:action_id]
    data = context[:data]
    existing_meta = context[:existing_meta]
    principal_role = context[:principal_role]
    action_kind = data["kind"]?.try(&.as_s?) || ""
    risk_class = data["risk_class"]?.try(&.as_s?) || "medium"

    if reason = _rejection_reason(principal_role, action_kind, risk_class)
      _reject_action(graph, action_id, data.to_json, existing_meta, reason)
    else
      new_meta = existing_meta.merge({
        "permission_checked" => JSON::Any.new(true),
        "checked_by"         => JSON::Any.new("permission_checker"),
        "principal_role"     => JSON::Any.new(principal_role),
      })
      merged = _merge_patch(data.to_json, {"metadata" => JSON::Any.new(new_meta)})
      begin
        graph.patch_object(action_id, merged)
      rescue
      end
    end
  end

  # Resolve the proposed-action context the permission decision needs:
  # the action id, its data, the action's metadata, and the proposing
  # principal's role. Returns nil when the check should be skipped.
  def self._permission_context(
    event : Chronicle::Event,
    graph : Chronicle::GraphProjection,
  ) : NamedTuple(action_id: String, data: JSON::Any, existing_meta: Hash(String, JSON::Any), principal_role: String)?
    payload = JSON.parse(event.payload)
    action_id = payload["id"]?.try(&.as_s?)
    return nil if action_id.nil?

    data = payload["data"]?
    return nil if data.nil?
    return nil unless (data["status"]?.try(&.as_s?)) == "proposed"

    existing_meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    principal_id = existing_meta["principal_id"]?.try(&.as_s?) || ""
    return nil if principal_id.empty?

    principal_obj = graph.get_object(principal_id)
    return nil if principal_obj.nil?

    role = JSON.parse(principal_obj.data)["role"]?.try(&.as_s?) || "unknown"
    {action_id: action_id, data: data, existing_meta: existing_meta, principal_role: role}
  end

  # The deterministic permission decision: the rejection reason for a
  # principal/action, or nil when the action is allowed.
  def self._rejection_reason(principal_role : String, action_kind : String, risk_class : String) : String?
    return "principal_blocked" if principal_role == "blocked"

    if risk_class.in?({"high", "critical"}) && !principal_role.in?({"owner", "admin"})
      return "risk_class_#{risk_class}_requires_owner_or_admin"
    end

    if action_kind.in?({"tool_call", "api_call", "external_write", "run_code"}) && !can_action?(principal_role, "execute")
      return "insufficient_role_for_execute"
    end

    nil
  end

  # Patch an action to 'rejected' with the rejection reason.
  def self._reject_action(
    graph : Chronicle::GraphProjection,
    action_id : String,
    current : String,
    existing_meta : Hash(String, JSON::Any),
    reason : String,
  ) : Nil
    new_meta = existing_meta.merge({
      "rejection_reason" => JSON::Any.new(reason),
      "checked_by"       => JSON::Any.new("permission_checker"),
    })
    merged = _merge_patch(current, {
      "status"   => JSON::Any.new("rejected"),
      "metadata" => JSON::Any.new(new_meta),
    })
    begin
      graph.patch_object(action_id, merged)
    rescue
    end
  end
end

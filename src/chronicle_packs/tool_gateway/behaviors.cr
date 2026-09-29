require "json"

module Chronicle::Packs::ToolGateway
  # Tool Gateway behaviors. Ported from upstream packs/tool_gateway/behaviors.py
  # (slice 1: call_recorder, policy_enforcer, call_executor, result_sourcer).
  # tool_policy_reliability_guard depends on standing_scopes (deferred).

  # Both policy dimensions for one call. P6 (ADR 0018): an R2 call is
  # auto-eligible only when a PROMOTED standing scope (tool_policy) covers
  # this capability AND the instance authority ceiling is at least R2 —
  # looked up live from *graph*, so a demotion takes effect on the very
  # next call.
  def self.evaluate_call_policy(capability_key : String, risk_class : String, action_class : String, settings : ToolGatewaySettings, requires_explicit_approval : Bool = false, graph : Chronicle::GraphProjection? = nil, authority_ceiling : String = "none") : Hash(String, JSON::Any)
    capability_ceiling = settings.capability_action_ceilings[capability_key]?
    standing_scope = (graph && action_class == "R2") ? promoted_standing_scope_for(graph, capability_key, "R2") : nil
    detail = decide_policy_detail(
      risk_class, settings,
      action_class: action_class,
      authority_ceiling: authority_ceiling,
      capability_ceiling: capability_ceiling,
      standing_scope: standing_scope,
    )
    if authority = detail["action_authority"]?.try(&.as_h)
      authority["capability"] = JSON::Any.new(capability_key)
    end
    if requires_explicit_approval
      detail["decision"] = JSON::Any.new("hold")
      detail["granted_by"] = JSON::Any.new("")
      authority = detail["action_authority"]?.try(&.as_h) || {} of String => JSON::Any
      authority["decision"] = JSON::Any.new("require_approval")
      authority["matched_policy"] = JSON::Any.new("call_requires_explicit_approval")
      authority["reason"] = JSON::Any.new("this call carries a stricter per-call approval requirement; neither legacy risk configuration nor a standing scope may bypass it")
      detail["action_authority"] = JSON::Any.new(authority)
    end
    detail
  end

  # Runtime-bound form of the policy decision.  A declared action class must
  # travel through Chronicle's canonical authority API so the durable
  # `authority.decision` receipt is emitted by the runtime, exactly as the
  # vendor proxy does.  The graph-only form above intentionally remains
  # unaudited: without a runtime it cannot grant through this path.
  def self.evaluate_call_policy(capability_key : String, risk_class : String, action_class : String, settings : ToolGatewaySettings, runtime : Chronicle::Runtime(M), requires_explicit_approval : Bool = false, graph : Chronicle::GraphProjection? = nil, actor : String = "gateway_llm_proxy") : Hash(String, JSON::Any) forall M
    ceiling = runtime.authority_ceiling
    detail = evaluate_call_policy(
      capability_key, risk_class, action_class, settings,
      requires_explicit_approval: requires_explicit_approval,
      graph: graph,
      authority_ceiling: ceiling,
    )
    return detail if action_class.empty?

    capability_ceiling = settings.capability_action_ceilings[capability_key]?
    standing_scope = graph && action_class == "R2" ? promoted_standing_scope_for(graph, capability_key, "R2") : nil
    audit_ceiling = capability_ceiling
    audit_ceiling = _stricter_ceiling(audit_ceiling, "R1") if action_class == "R2" && standing_scope.nil?
    audit_ceiling = _stricter_ceiling(audit_ceiling, "none") if requires_explicit_approval
    audited = runtime.evaluate_capability_authority(
      capability: capability_key,
      action_class: action_class,
      capability_ceiling: audit_ceiling,
      actor: actor,
    )
    authority = detail["action_authority"]?.try(&.as_h) || {} of String => JSON::Any
    authority["capability"] = JSON::Any.new(audited.capability)
    authority["action_class"] = JSON::Any.new(audited.action_class)
    authority["ceiling"] = JSON::Any.new(audited.ceiling)
    authority["capability_ceiling"] = audited.capability_ceiling ? JSON::Any.new(audited.capability_ceiling) : JSON::Any.new(nil)
    authority["effective_ceiling"] = JSON::Any.new(audited.effective_ceiling)
    authority["audit_event_id"] = JSON::Any.new(audited.event_id)
    detail["action_authority"] = JSON::Any.new(authority)
    detail
  end

  # Record a proposed capability call and create its provider relation.
  @[Chronicle::Packs::Annotations::Behavior(name: "call_recorder", on: ["object.created"], where: {"type" => "capability_call"})]
  def call_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ToolGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    call_id = payload["id"]?.try(&.as_s?)
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    provider_id = data["provider_id"]?.try(&.as_s?)
    return if provider_id.nil? || call_id.nil?

    graph.add_relation(call_id, provider_id, "calls")
  end

  # Check a proposed capability call against the policy configuration.
  @[Chronicle::Packs::Annotations::Behavior(name: "policy_enforcer", on: ["object.created"], where: {"type" => "capability_call"}, creates: ["capability_approval"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream policy gating
  def policy_enforcer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ToolGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    call_id = payload["id"]?.try(&.as_s?)
    return if call_id.nil?

    call_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    risk_class = call_data["risk_class"]?.try(&.as_s?) || "medium"
    action_class = call_data["action_class"]?.try(&.as_s?) || ""
    return unless call_data["status"]?.try(&.as_s?) == "proposed"

    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
    capability_key = "#{call_data["provider_name"]?.try(&.as_s?) || ""}.#{call_data["capability_name"]?.try(&.as_s?) || ""}"
    policy = evaluate_call_policy(
      capability_key, risk_class, action_class, settings,
      requires_explicit_approval: (call_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["requires_explicit_approval"]?.try(&.as_bool?) || false,
    )

    if policy["decision"]?.try(&.as_s?) == "auto_approve"
      if current = graph.get_object(call_id)
        graph.patch_object(call_id, CapabilityCall.from_json(current.data).copy_with(status: CallStatus::Approved).to_json)
      end
      metadata = {"risk_class" => JSON::Any.new(risk_class)}
      if !action_class.empty?
        metadata["granted_by"] = policy["granted_by"]? || JSON::Any.new("")
        metadata["action_authority"] = policy["action_authority"]? || JSON::Any.new({} of String => JSON::Any)
      end
      approval = CapabilityApproval.new(
        call_id,
        provider_id: call_data["provider_id"]?.try(&.as_s?) || "",
        provider_name: call_data["provider_name"]?.try(&.as_s?) || "",
        capability_name: call_data["capability_name"]?.try(&.as_s?) || "",
        action_class: action_class,
        input_data: call_data["input_data"]?.try(&.as_h) || {} of String => JSON::Any,
        credential_ref_name: call_data["credential_ref_name"]?.try(&.as_s?),
        credential_ref_id: call_data["credential_ref_id"]?.try(&.as_s?),
        frame_id: call_data["frame_id"]?.try(&.as_s?),
        policy_decision: "auto_approved", approver: "policy_enforcer", approved_at: now,
        metadata: metadata,
      )
      approval_obj = graph.add_object("capability_approval", approval.to_json)
      graph.add_relation(call_id, approval_obj.id, "approved_by")
    else
      if current = graph.get_object(call_id)
        graph.patch_object(call_id, CapabilityCall.from_json(current.data).copy_with(status: CallStatus::PolicyChecking).to_json)
      end
      if !action_class.empty? && (current = graph.get_object(call_id))
        call = CapabilityCall.from_json(current.data)
        call_metadata = call.metadata.dup
        call_metadata["action_authority"] = policy["action_authority"]? || JSON::Any.new({} of String => JSON::Any)
        call_metadata["granted_by"] = policy["granted_by"]? || JSON::Any.new("")
        graph.patch_object(call_id, call.copy_with(metadata: call_metadata).to_json)
      end
    end
  end

  # Execute an approved capability call and create a CapabilityResult.
  @[Chronicle::Packs::Annotations::Behavior(name: "call_executor", on: ["object.created"], where: {"type" => "capability_approval"}, creates: ["capability_result"])]
  def call_executor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ToolGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    approval_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    call_id = approval_data["call_id"]?.try(&.as_s?) || ""
    capability_name = approval_data["capability_name"]?.try(&.as_s?) || ""
    return if call_id.empty? || capability_name.empty?

    call = graph.get_object(call_id)
    return if call.nil? || (JSON.parse(call.data)["status"]?.try(&.as_s?) != "approved")

    execute_approved_call(graph, call_id, approval_data, settings, executed_by: "call_executor")
  end

  # Map a capability result to a Core source object.
  @[Chronicle::Packs::Annotations::Behavior(name: "result_sourcer", on: ["object.created"], where: {"type" => "capability_result"}, creates: ["source"])]
  def result_sourcer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ToolGatewaySettings) : Nil
    return if !settings.create_source_from_result?

    payload = JSON.parse(event.payload).as_h
    result_id = payload["id"]?.try(&.as_s?)
    return if result_id.nil?

    result_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    output_data = result_data["output_data"]?.try(&.as_s?) || ""
    return if output_data.empty?

    provider_name = result_data["provider_name"]?.try(&.as_s?) || "unknown"
    capability_name = result_data["capability_name"]?.try(&.as_s?) || "unknown"
    frame_id = result_data["frame_id"]?.try(&.as_s?)
    call_id = result_data["call_id"]?.try(&.as_s?) || ""
    content = output_data[0, settings.max_output_chars]

    source = graph.add_object("source", JSON.build do |json|
      json.object do
        json.field "kind", "tool_result"
        json.field "content", content
        json.field "url", JSON::Any.new(nil)
        json.field "channel", "tool_gateway"
        json.field "sender_ref", "#{provider_name}.#{capability_name}"
        json.field "frame_id", frame_id ? JSON::Any.new(frame_id) : JSON::Any.new(nil)
        json.field "metadata", JSON::Any.new({"call_id" => JSON::Any.new(call_id), "provider" => JSON::Any.new(provider_name), "capability" => JSON::Any.new(capability_name)})
      end
    end)

    if current = graph.get_object(result_id)
      result = CapabilityResult.from_json(current.data)
      graph.patch_object(result_id, result.copy_with(source_id: source.id).to_json)
    end
    graph.add_relation(result_id, source.id, "sourced_as")
  end

  # Demote a promoted standing scope whose reliability turns bad.
  # Unlike skills, recovery NEVER auto-re-promotes an automation grant:
  # re-promotion always takes a fresh proposal plus explicit owner approval
  # (ADR 0018: promotion is never silent).
  @[Chronicle::Packs::Annotations::Behavior(name: "tool_policy_reliability_guard", on: ["reliability.changed"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream guard's verdict gating
  def tool_policy_reliability_guard(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ToolGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    return unless payload["artifact_type"]?.try(&.as_s?) == "tool_policy"
    verdict = payload["verdict"]?.try(&.as_s?) || "weak"
    return unless verdict.in?({"harmful", "stale"})

    artifact_id = payload["artifact_id"]?.try(&.as_s?) || ""
    policy = graph.get_object(artifact_id)
    if policy.nil? || policy.type != "tool_policy"
      policy = graph.objects(type: "tool_policy").find { |obj| JSON.parse(obj.data)["policy_id"]?.try(&.as_s?) == artifact_id }
    end
    return if policy.nil?

    policy_data = JSON.parse(policy.data).as_h
    return unless policy_data["status"]?.try(&.as_s?) == "promoted"

    outcome_event_id = payload["outcome_event_id"]?.try(&.as_s?) || ""
    evidence = policy_data["evidence"]?.try(&.as_h) || {} of String => JSON::Any
    demote_tool_policy_fn(
      graph,
      policy_data["policy_id"]?.try(&.as_s?) || "",
      missed_prediction_refs: [event.id],
      observed_accuracy_percent: evidence["accuracy_percent"]?.try(&.as_i?) || 0,
      actor: "tool_policy_reliability_guard",
      reason: "reliability verdict fell to #{verdict.inspect} (outcome evidence #{outcome_event_id})",
    )
  end
end

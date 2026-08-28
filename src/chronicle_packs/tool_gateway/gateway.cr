require "json"

module Chronicle::Packs::ToolGateway
  # Tool Gateway mechanics shared by the reactive behaviors. Ported from
  # upstream packs/tool_gateway/gateway.py. decide_policy_detail is the
  # single policy decision; execute_approved_call is the single execution
  # implementation (credential injection via a host seam, sanitization,
  # injection scan, result recording).

  # The lower of two ceiling values; nil means unconstrained.
  def self._stricter_ceiling(a : String?, b : String?) : String?
    order = ["none", "R0", "R1", "R2"]
    if a.nil?
      return b
    end
    if b.nil?
      return a
    end
    a_index = order.index(a) || 0
    b_index = order.index(b) || 0
    a_index <= b_index ? a : b
  end

  # The runtime's pure action-authority evaluation (CONTRACT v1.9). R4
  # routes to the governance gate, R3 requires approval, missing/invalid
  # classes fail closed, and the effective ceiling is the stricter of the
  # instance ceiling and any per-capability ceiling.
  def self.evaluate_action_authority(capability : String, action_class : String, ceiling : String, capability_ceiling : String? = nil) : Hash(String, JSON::Any)
    order = {"none" => 0, "R0" => 1, "R1" => 2, "R2" => 3, "R3" => 4, "R4" => 5}
    effective = _stricter_ceiling(ceiling, capability_ceiling)
    reason = "within_ceiling"
    decision = "auto_approve"
    matched_policy = "within_ceiling"
    if !order.has_key?(action_class)
      decision = "require_approval"
      matched_policy = "fail_closed_missing_action_class"
      reason = "no canonical action_class is declared for this capability; it is ineligible for action-class auto-approval (ADR 0016)"
    elsif action_class == "R4"
      decision = "require_approval"
      matched_policy = "governance_gate"
      reason = "R4 is a governance action and never auto-approves through the ceiling path"
    elsif action_class == "R3"
      decision = "require_approval"
      matched_policy = "requires_approval"
      reason = "R3 actions require explicit approval"
    elsif (order[action_class] || 0) > (order[effective]? || 0)
      decision = "require_approval"
      matched_policy = "above_ceiling"
      reason = "action_class #{action_class} exceeds the effective ceiling #{effective}"
    end
    {
      "capability"         => JSON::Any.new(capability),
      "action_class"       => JSON::Any.new(action_class),
      "decision"           => JSON::Any.new(decision),
      "matched_policy"     => JSON::Any.new(matched_policy),
      "reason"             => JSON::Any.new(reason),
      "ceiling"            => JSON::Any.new(ceiling),
      "capability_ceiling" => capability_ceiling.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
      "effective_ceiling"  => effective.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
    }
  end

  # The gateway's one policy decision with the per-dimension record.
  def self.decide_policy_detail(risk_class : String, settings : ToolGatewaySettings, action_class : String = "", authority_ceiling : String = "none", capability_ceiling : String? = nil, standing_scope : Hash(String, JSON::Any)? = nil) : Hash(String, JSON::Any)
    legacy_grants = settings.auto_approve_risk_classes.includes?(risk_class)
    authority = evaluate_action_authority("", action_class, authority_ceiling, capability_ceiling)
    action_record = authority.dup
    action_record["standing_scope"] = standing_scope ? JSON::Any.new(standing_scope) : JSON::Any.new(nil)
    if action_class == "R2" && action_record["decision"]?.try(&.as_s?) == "auto_approve" && standing_scope.nil?
      action_record["decision"] = JSON::Any.new("require_approval")
      action_record["matched_policy"] = JSON::Any.new("r2_requires_promoted_standing_scope")
      action_record["reason"] = JSON::Any.new("R2 is within the ceiling but auto-approval of a bounded reversible capability requires a PROMOTED standing scope (tool_policy) covering it; none is promoted for this capability (ADR 0018)")
    end
    action_grants = action_record["decision"]?.try(&.as_s?) == "auto_approve"
    granted = [] of String
    granted << "legacy_risk" if legacy_grants
    granted << "action_authority" if action_grants
    {
      "decision"         => JSON::Any.new(granted.empty? ? "hold" : "auto_approve"),
      "legacy_risk"      => JSON::Any.new({"risk_class" => JSON::Any.new(risk_class), "auto_approve" => JSON::Any.new(legacy_grants)}),
      "action_authority" => JSON::Any.new(action_record),
      "granted_by"       => JSON::Any.new(granted.join("+")),
    }
  end

  def self.decide_policy(risk_class : String, settings : ToolGatewaySettings, action_class : String = "", authority_ceiling : String = "none", capability_ceiling : String? = nil, standing_scope : Hash(String, JSON::Any)? = nil) : String
    decide_policy_detail(risk_class, settings, action_class: action_class, authority_ceiling: authority_ceiling, capability_ceiling: capability_ceiling, standing_scope: standing_scope)["decision"].as_s
  end

  # Host seam: a resolver for credential_ref_name -> secret value. When unset
  # (or when the Secrets pack is not wired), injection is skipped silently.
  class_property credential_resolver : Proc(Chronicle::GraphProjection, String, String?, String?)?

  # Execute an approved capability call and record everything.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream execution pipeline
  def self.execute_approved_call(graph : Chronicle::GraphProjection, call_id : String, call_data : Hash(String, JSON::Any), settings : ToolGatewaySettings, executed_by : String = "call_executor") : Hash(String, JSON::Any)
    provider_name = call_data["provider_name"]?.try(&.as_s?) || ""
    capability_name = call_data["capability_name"]?.try(&.as_s?) || ""
    input_data = call_data["input_data"]?.try(&.as_h) || {} of String => JSON::Any
    frame_id = call_data["frame_id"]?.try(&.as_s?)

    _patch_status(graph, call_id, "executing")

    credential_ref_name = call_data["credential_ref_name"]?.try(&.as_s?)
    credential_ref_id = call_data["credential_ref_id"]?.try(&.as_s?)
    execution_context = {"graph" => JSON::Any.new("graph"), "call_id" => JSON::Any.new(call_id)}
    if settings.inject_credentials? && credential_ref_name && credential_resolver
      if resolver = credential_resolver
        secret_value = resolver.call(graph, credential_ref_name, credential_ref_id)
        if secret_value
          execution_context["credential"] = JSON::Any.new(secret_value)
        end
      end
    end

    result_data = execute_capability_fn(provider_name, capability_name, input_data, call_id: call_id, frame_id: frame_id, execution_context: execution_context)
    raw_output = (result_data["output_data"]?.try(&.as_s?) || "")[0, settings.max_output_chars]

    was_sanitized = false
    if settings.sanitize_output? && !raw_output.empty?
      raw_output, was_sanitized = Sanitizer.sanitize_output(raw_output)
    end

    injection_flags = [] of String
    if settings.injection_scan? && !raw_output.empty?
      injection_flags = Untrusted.scan_for_injection(raw_output)
    end

    stored_output = settings.record_output_data? ? raw_output : ""
    result = CapabilityResult.new(
      call_id, provider_name, capability_name,
      output_data: stored_output, error: result_data["error"]?.try(&.as_s?),
      success: result_data["success"]?.try(&.as_bool?) != false,
      executed_at: result_data["executed_at"]?.try(&.as_s?),
      sanitized: was_sanitized, untrusted: true, injection_flags: injection_flags,
      frame_id: frame_id,
    )
    result_obj = graph.add_object("capability_result", result.to_json)

    if !injection_flags.empty?
      flag = InjectionFlag.new(
        call_id, result_obj.id, provider_name, capability_name,
        patterns: injection_flags, excerpt: raw_output[0, 300],
        flagged_at: Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ"), frame_id: frame_id,
      )
      flag_obj = graph.add_object("injection_flag", flag.to_json)
      graph.add_relation(flag_obj.id, result_obj.id, "flags")
    end

    new_status = (result_data["success"]?.try(&.as_bool?) || true) ? "done" : "failed"
    _patch_status(graph, call_id, new_status)
    graph.add_relation(call_id, result_obj.id, "produces_result")

    {
      "output_data"     => JSON::Any.new(stored_output),
      "error"           => result_data["error"]? || JSON::Any.new(nil),
      "success"         => result_data["success"]? || JSON::Any.new(true),
      "executed_at"     => result_data["executed_at"]? || JSON::Any.new(nil),
      "sanitized"       => JSON::Any.new(was_sanitized),
      "injection_flags" => JSON::Any.new(injection_flags.map { |label| JSON::Any.new(label) }),
      "result_id"       => JSON::Any.new(result_obj.id),
      "status"          => JSON::Any.new(new_status),
    }
  end

  # Merge-patch a capability_call status field via typed copy_with.
  def self._patch_status(graph : Chronicle::GraphProjection, call_id : String, status : String) : Nil
    current = graph.get_object(call_id)
    return if current.nil?

    call = CapabilityCall.from_json(current.data)
    graph.patch_object(call_id, call.copy_with(status: CallStatus.parse?(status) || CallStatus::Failed).to_json)
  end
end

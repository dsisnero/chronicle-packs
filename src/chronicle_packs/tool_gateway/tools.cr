require "json"
require "digest"

module Chronicle::Packs::ToolGateway
  # Tool Gateway Pack tools. Ported from upstream packs/tool_gateway/tools.py.
  # The local capability registry plus approval resolution. In production,
  # behaviors create a CapabilityCall (proposed), policy_enforcer approves
  # it, and call_executor executes — all graph-visible and policy-gated.

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # A registered local capability: handler plus the metadata that lets the
  # gateway expose it safely and policy-check it.
  record CapabilitySpec,
    provider_name : String,
    capability_name : String,
    fn : Proc(Hash(String, JSON::Any), Hash(String, JSON::Any)),
    description : String = "",
    risk_class : String = "low",
    credential_ref_name : String? = nil,
    origin : String = "native",
    action_class : String = "",
    input_schema_available : Bool = true,
    input_schema : JSON::Any? = nil do
    def key : String
      "#{provider_name}.#{capability_name}"
    end
  end

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module LocalRegistry
    REGISTRY = {} of String => CapabilitySpec
  end

  def self.register_local_capability(provider_name : String, capability_name : String, fn : Proc(Hash(String, JSON::Any), Hash(String, JSON::Any)), description : String = "", risk_class : String = "low", credential_ref_name : String? = nil, origin : String = "native", action_class : String = "", input_schema_available : Bool = true, input_schema : JSON::Any? = nil) : CapabilitySpec
    unless action_class.in?({"", "R0", "R1", "R2", "R3", "R4"})
      raise ArgumentError.new("capability #{provider_name}.#{capability_name}: action_class #{action_class.inspect} must be one of R0|R1|R2|R3|R4 (or omitted). Legacy risk labels are a different dimension and never map.")
    end
    check_registration(provider_name, capability_name, risk_class, origin: origin, action_class: action_class)
    spec = CapabilitySpec.new(provider_name, capability_name, fn, description, risk_class, credential_ref_name, origin, action_class, input_schema_available, input_schema)
    LocalRegistry::REGISTRY[spec.key] = spec
    spec
  end

  def self.get_capability_spec(key : String) : CapabilitySpec?
    LocalRegistry::REGISTRY[key]?
  end

  def self.clear_local_registry : Nil
    LocalRegistry::REGISTRY.clear
  end

  def self.registered_capability_keys : Array(String)
    LocalRegistry::REGISTRY.keys
  end

  # Dispatch a capability call to the appropriate handler (registry or mock).
  def self.execute_capability_fn(provider_name : String, capability_name : String, input_data : Hash(String, JSON::Any), call_id : String = "", frame_id : String? = nil, execution_context : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
    key = "#{provider_name}.#{capability_name}"
    credential_injected = execution_context.has_key?("credential")
    begin
      output_str = if spec = LocalRegistry::REGISTRY[key]?
                     result = spec.fn.call(input_data)
                     result.to_json
                   else
                     JSON::Any.new({"mock" => JSON::Any.new(true), "provider" => JSON::Any.new(provider_name), "capability" => JSON::Any.new(capability_name), "inputs" => JSON::Any.new(input_data), "note" => JSON::Any.new("No handler registered for '#{key}'. Register via register_local_capability().")}).to_json
                   end
      {"output_data" => JSON::Any.new(output_str), "error" => JSON::Any.new(nil), "success" => JSON::Any.new(true), "executed_at" => JSON::Any.new(now), "credential_injected" => JSON::Any.new(credential_injected)}
    rescue ex
      {"output_data" => JSON::Any.new(""), "error" => JSON::Any.new("#{ex.class}: #{ex}"), "success" => JSON::Any.new(false), "executed_at" => JSON::Any.new(now), "credential_injected" => JSON::Any.new(credential_injected)}
    end
  end

  # Check that an approver_ref may resolve held calls (Identity/Auth optional).
  def self._verify_approver(graph : Chronicle::GraphProjection, approver_ref : String, approver_roles : Array(String)) : Hash(String, JSON::Any)
    any_principals = !graph.objects(type: "principal").empty?
    if !any_principals
      return {"allowed" => JSON::Any.new(true), "verification" => JSON::Any.new("identity_unverified"), "role" => JSON::Any.new(nil), "reason" => JSON::Any.new("no principals registered")}
    end
    principal = IdentityAuth.lookup_principal_fn(graph, approver_ref)
    if principal.nil?
      return {"allowed" => JSON::Any.new(false), "verification" => JSON::Any.new("identity_verified"), "role" => JSON::Any.new(nil), "reason" => JSON::Any.new("approver #{approver_ref.inspect} does not resolve to a principal")}
    end
    role = principal["role"]?.try(&.as_s?) || "unknown"
    if approver_roles.includes?(role)
      return {"allowed" => JSON::Any.new(true), "verification" => JSON::Any.new("identity_verified"), "role" => JSON::Any.new(role), "reason" => JSON::Any.new("role_allows")}
    end
    {"allowed" => JSON::Any.new(false), "verification" => JSON::Any.new("identity_verified"), "role" => JSON::Any.new(role), "reason" => JSON::Any.new("role #{role.inspect} not in approver_roles #{approver_roles.inspect}")}
  end

  # List capability calls held for manual approval (FIFO).
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream pending-approvals surface
  def self.pending_approvals_fn(graph : Chronicle::GraphProjection) : Array(Hash(String, JSON::Any))
    pending = [] of Hash(String, JSON::Any)
    graph.objects(type: "capability_call").each do |obj|
      data = JSON.parse(obj.data).as_h
      next unless data["status"]?.try(&.as_s?) == "policy_checking"

      action_class = data["action_class"]?.try(&.as_s?) || ""
      authority = (data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["action_authority"]?.try(&.as_h) || {} of String => JSON::Any
      declined_because = if !authority.empty?
                           {"matched_policy" => authority["matched_policy"]? || JSON::Any.new(""), "reason" => authority["reason"]? || JSON::Any.new(""), "ceiling" => authority["ceiling"]? || JSON::Any.new(nil), "capability_ceiling" => authority["capability_ceiling"]? || JSON::Any.new(nil)}
                         elsif action_class.empty?
                           {"matched_policy" => JSON::Any.new("fail_closed_missing_action_class"), "reason" => JSON::Any.new("no canonical action_class is declared for this capability; it is ineligible for action-class auto-approval (ADR 0016)"), "ceiling" => JSON::Any.new(nil), "capability_ceiling" => JSON::Any.new(nil)}
                         else
                           nil
                         end
      pending << {
        "call_id"                       => JSON::Any.new(obj.id),
        "provider_name"                 => data["provider_name"]? || JSON::Any.new(""),
        "capability_name"               => data["capability_name"]? || JSON::Any.new(""),
        "risk_class"                    => data["risk_class"]? || JSON::Any.new("medium"),
        "action_class"                  => data["action_class"]? || JSON::Any.new(""),
        "auto_approve_declined_because" => declined_because ? JSON::Any.new(declined_because) : JSON::Any.new(nil),
        "input_data"                    => data["input_data"]? || JSON::Any.new({} of String => JSON::Any),
        "proposed_by"                   => data["proposed_by"]? || JSON::Any.new(nil),
        "proposed_at"                   => data["proposed_at"]? || JSON::Any.new(nil),
        "frame_id"                      => data["frame_id"]? || JSON::Any.new(nil),
      }
    end
    pending.sort_by! { |row| row["proposed_at"]?.try(&.as_s?) || "" }
    pending
  end

  # Approve a held capability call so call_executor runs it.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream approval resolution
  def self.approve_capability_fn(graph : Chronicle::GraphProjection, call_id : String, approver_ref : String, note : String = "", approver_roles : Array(String)? = nil) : Hash(String, JSON::Any)
    roles = approver_roles || ToolGatewaySettings.new.approver_roles
    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
    call = graph.get_object(call_id)
    if call.nil? || call.type != "capability_call"
      return {"ok" => JSON::Any.new(false), "approval_id" => JSON::Any.new(nil), "reason" => JSON::Any.new("no capability_call #{call_id.inspect}")}
    end
    call_data = JSON.parse(call.data).as_h
    status = call_data["status"]?.try(&.as_s?)
    if status != "policy_checking"
      return {"ok" => JSON::Any.new(false), "approval_id" => JSON::Any.new(nil), "reason" => JSON::Any.new("call is #{status.inspect}, not 'policy_checking' — only held calls can be approved")}
    end

    verdict = _verify_approver(graph, approver_ref, roles)
    unless verdict["allowed"]?.try(&.as_bool?) || false
      return {"ok" => JSON::Any.new(false), "approval_id" => JSON::Any.new(nil), "reason" => verdict["reason"]? || JSON::Any.new(nil)}
    end

    call = CapabilityCall.from_json(call.data).copy_with(status: CallStatus::Approved)
    graph.patch_object(call_id, call.to_json)
    approval = CapabilityApproval.new(
      call_id,
      provider_id: call_data["provider_id"]?.try(&.as_s?) || "",
      provider_name: call_data["provider_name"]?.try(&.as_s?) || "",
      capability_name: call_data["capability_name"]?.try(&.as_s?) || "",
      action_class: call_data["action_class"]?.try(&.as_s?) || "",
      input_data: call_data["input_data"]?.try(&.as_h) || {} of String => JSON::Any,
      credential_ref_name: call_data["credential_ref_name"]?.try(&.as_s?),
      credential_ref_id: call_data["credential_ref_id"]?.try(&.as_s?),
      frame_id: call_data["frame_id"]?.try(&.as_s?),
      policy_decision: "manual", approver: approver_ref, approved_at: now,
      metadata: {"risk_class" => call_data["risk_class"]? || JSON::Any.new("medium"), "note" => JSON::Any.new(note), "verification" => verdict["verification"]? || JSON::Any.new(""), "approver_role" => verdict["role"]? || JSON::Any.new(nil)},
    )
    approval_obj = graph.add_object("capability_approval", approval.to_json)
    graph.add_relation(call_id, approval_obj.id, "approved_by")
    {"ok" => JSON::Any.new(true), "approval_id" => JSON::Any.new(approval_obj.id), "reason" => JSON::Any.new("approved")}
  end

  # Deny a held capability call — an audited refusal, not a status flip.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream denial resolution
  def self.deny_capability_fn(graph : Chronicle::GraphProjection, call_id : String, approver_ref : String, reason : String = "", approver_roles : Array(String)? = nil) : Hash(String, JSON::Any)
    roles = approver_roles || ToolGatewaySettings.new.approver_roles
    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
    call = graph.get_object(call_id)
    if call.nil? || call.type != "capability_call"
      return {"ok" => JSON::Any.new(false), "denial_id" => JSON::Any.new(nil), "reason" => JSON::Any.new("no capability_call #{call_id.inspect}")}
    end
    call_data = JSON.parse(call.data).as_h
    status = call_data["status"]?.try(&.as_s?)
    if status != "policy_checking"
      return {"ok" => JSON::Any.new(false), "denial_id" => JSON::Any.new(nil), "reason" => JSON::Any.new("call is #{status.inspect}, not 'policy_checking' — only held calls can be denied")}
    end

    verdict = _verify_approver(graph, approver_ref, roles)
    unless verdict["allowed"]?.try(&.as_bool?) || false
      return {"ok" => JSON::Any.new(false), "denial_id" => JSON::Any.new(nil), "reason" => verdict["reason"]? || JSON::Any.new(nil)}
    end

    call = CapabilityCall.from_json(call.data).copy_with(status: CallStatus::Rejected)
    graph.patch_object(call_id, call.to_json)
    denial = CapabilityDenial.new(
      call_id, approver_ref, reason,
      provider_name: call_data["provider_name"]?.try(&.as_s?) || "",
      capability_name: call_data["capability_name"]?.try(&.as_s?) || "",
      action_class: call_data["action_class"]?.try(&.as_s?) || "",
      denied_at: now, frame_id: call_data["frame_id"]?.try(&.as_s?),
      metadata: {"risk_class" => call_data["risk_class"]? || JSON::Any.new("medium"), "verification" => verdict["verification"]? || JSON::Any.new(""), "denier_role" => verdict["role"]? || JSON::Any.new(nil)},
    )
    denial_obj = graph.add_object("capability_denial", denial.to_json)
    graph.add_relation(call_id, denial_obj.id, "denied_by")
    {"ok" => JSON::Any.new(true), "denial_id" => JSON::Any.new(denial_obj.id), "reason" => JSON::Any.new("denied")}
  end

  @[Chronicle::Packs::Annotations::Tool(name: "execute_capability", description: "Execute an approved capability call and return the result. Call this ONLY after policy_enforcer has set status='approved'.", deterministic: true)]
  def execute_capability_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = execute_capability_fn(
      input["provider_name"]?.try(&.as_s?) || "", input["capability_name"]?.try(&.as_s?) || "",
      input["input_data"]?.try(&.as_h) || {} of String => JSON::Any,
      call_id: input["call_id"]?.try(&.as_s?) || "",
      frame_id: input["frame_id"]?.try(&.as_s?),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "pending_approvals", description: "List capability calls held for manual approval (status='policy_checking'). The graph is the single source of truth.", deterministic: true)]
  def pending_approvals_tool(args : String) : String
    JSON::Any.new(pending_approvals_fn(bound_graph_or_raise).map { |row| JSON::Any.new(row) }).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "approve_capability", description: "Approve a capability call held at status='policy_checking'. Creates the capability_approval object that triggers call_executor.", deterministic: true)]
  def approve_capability_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = approve_capability_fn(
      bound_graph_or_raise,
      input["call_id"]?.try(&.as_s?) || "",
      input["approver_ref"]?.try(&.as_s?) || "",
      note: input["note"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "deny_capability", description: "Deny a capability call held at status='policy_checking'. Patches the call to 'rejected' and records a capability_denial.", deterministic: true)]
  def deny_capability_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = deny_capability_fn(
      bound_graph_or_raise,
      input["call_id"]?.try(&.as_s?) || "",
      input["approver_ref"]?.try(&.as_s?) || "",
      reason: input["reason"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "tool_gateway tools require a bound graph (set ToolGateway.bound_graph)"
    )
  end
end

require "json"
require "crig"

module Chronicle::Packs::ToolGateway
  # LLM tool proxies — chat that can act, without bypassing the gateway.
  # Ported from upstream packs/tool_gateway/llm_tools.py. The tool a model
  # calls is never a raw capability: it is a Crig tool (CrigGatewayTool, a
  # Crig::DynamicTool implementing Crig::ToolDyn) whose callback runs the
  # shared gateway pipeline — capability_call (audit before action) ->
  # decide_policy -> either execute inline (auto-approved, result returned
  # in the same tool turn) or hold for explicit approval. Crig supplies the
  # tool transport (JSON args, ToolContext, ToolResult); the gateway owns
  # the policy state machine.

  # Inbound typed metadata the Crig ToolContext may carry for a dispatch:
  # tool_call_id, run/turn, behavior/agent identity, and idempotency. The
  # adapter persists these on the capability_call so the trace reads
  # llm.requested -> tool.requested -> capability_call -> capability_result.
  record GatewayToolMetadata,
    tool_call_id : String? = nil,
    run_id : String? = nil,
    behavior_name : String? = nil,
    frame_id : String? = nil,
    idempotency_key : String? = nil do
    include JSON::Serializable
  end

  # A Crig tool adapter over one gateway capability. Implements
  # Crig::ToolDyn so a Crig::ToolSet / agent tool server can invoke it; the
  # callback delegates every decision to the gateway's shared mechanics.
  class CrigGatewayTool < Crig::DynamicTool
    getter spec : CapabilitySpec
    getter graph : Chronicle::GraphProjection
    getter settings : ToolGatewaySettings
    getter authority_ceiling : String
    getter provider_id : String

    def initialize(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings, provider_id : String = "", authority_ceiling : String = "none")
      @spec = spec
      @graph = graph
      @settings = settings
      @authority_ceiling = authority_ceiling
      @provider_id = provider_id
      description = spec.description.empty? ? "Gateway capability #{spec.key}." : spec.description
      parameters = spec.input_schema || CrigGatewayTool.default_parameters
      super(spec.key, description, parameters) do |args, context|
        input = begin
          JSON.parse(args).as_h
        rescue ex : JSON::ParseException
          next Crig::Tool::ToolResult.failed(Crig::Tool::ToolExecutionError.invalid_args("tool arguments were not a JSON object: #{ex.message}"))
        end
        metadata = context.get(GatewayToolMetadata)
        outcome = Chronicle::Packs::ToolGateway._llm_proxy_pipeline(graph, spec, settings, authority_ceiling, provider_id, input, metadata)
        status = outcome["status"]?.try(&.as_s?) || ""
        if status == "held_for_approval"
          Crig::Tool::ToolResult.success(Crig::Tool::ToolOutput.json(JSON::Any.new(outcome)))
        else
          output = outcome["output"]?.try(&.as_s?) || ""
          Crig::Tool::ToolResult.success(Crig::Tool::ToolOutput.text(output))
        end
      end
    end

    def self.default_parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{},"additionalProperties":true}))
    end
  end

  # The runtime-aware variant retains the runtime only to invoke its
  # authority-decision audit boundary. Capability policy and execution remain
  # owned by the gateway pipeline.
  class RuntimeCrigGatewayTool(M) < Crig::DynamicTool
    def initialize(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings, runtime : Chronicle::Runtime(M), provider_id : String = "")
      description = spec.description.empty? ? "Gateway capability #{spec.key}." : spec.description
      parameters = spec.input_schema || CrigGatewayTool.default_parameters
      super(spec.key, description, parameters) do |args, context|
        input = begin
          JSON.parse(args).as_h
        rescue ex : JSON::ParseException
          next Crig::Tool::ToolResult.failed(Crig::Tool::ToolExecutionError.invalid_args("tool arguments were not a JSON object: #{ex.message}"))
        end
        metadata = context.get(GatewayToolMetadata)
        outcome = Chronicle::Packs::ToolGateway._llm_proxy_pipeline(graph, spec, settings, runtime, provider_id, input, metadata)
        if outcome["status"]?.try(&.as_s?) == "held_for_approval"
          Crig::Tool::ToolResult.success(Crig::Tool::ToolOutput.json(JSON::Any.new(outcome)))
        else
          Crig::Tool::ToolResult.success(Crig::Tool::ToolOutput.text(outcome["output"]?.try(&.as_s?) || ""))
        end
      end
    end
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # The shared gateway pipeline behind every LLM tool call. Records the
  # capability_call with its pre-decided policy outcome, then either returns
  # a structured held_for_approval payload or executes inline (approval
  # recorded after execution so call_executor's 'approved' guard skips it —
  # one approval, at most one execution).
  def self._llm_proxy_pipeline(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings, authority_ceiling : String, provider_id : String, input_data : Hash(String, JSON::Any), metadata : GatewayToolMetadata?) : Hash(String, JSON::Any)
    policy = evaluate_call_policy(
      spec.key, spec.risk_class, spec.action_class, settings,
      graph: graph,
      authority_ceiling: authority_ceiling,
    )
    _llm_proxy_pipeline_with_policy(graph, spec, settings, provider_id, input_data, metadata, policy)
  end

  # The mutation half shared by graph-only and runtime-audited entrypoints.
  # The policy is deliberately computed before `capability_call` so the call
  # carries its exact decision and the runtime audit, when present, precedes
  # the call just as it does upstream.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream proxy's audit-before-action flow
  def self._llm_proxy_pipeline_with_policy(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings, provider_id : String, input_data : Hash(String, JSON::Any), metadata : GatewayToolMetadata?, policy : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    decision = policy["decision"]?.try(&.as_s?) || "hold"
    now = _now_iso
    behavior_name = metadata.try(&.behavior_name) || "gateway_llm_proxy"

    call_obj = graph.add_object("capability_call", JSON.build do |json|
      json.object do
        json.field "provider_id", provider_id
        json.field "provider_name", spec.provider_name
        json.field "capability_name", spec.capability_name
        json.field "input_data", JSON::Any.new(input_data)
        json.field "credential_ref_name", spec.credential_ref_name ? JSON::Any.new(spec.credential_ref_name) : JSON::Any.new(nil)
        json.field "risk_class", spec.risk_class
        json.field "action_class", spec.action_class
        json.field "status", decision == "auto_approve" ? "approved" : "policy_checking"
        json.field "proposed_by", behavior_name
        json.field "frame_id", metadata.try(&.frame_id) ? JSON::Any.new(metadata.try(&.frame_id)) : JSON::Any.new(nil)
        json.field "proposed_at", now
        call_metadata = {} of String => JSON::Any
        call_metadata["initiated_by"] = JSON::Any.new("llm_tool_loop")
        call_metadata["tool_call_id"] = JSON::Any.new(metadata.try(&.tool_call_id) || "")
        call_metadata["run_id"] = JSON::Any.new(metadata.try(&.run_id) || "")
        call_metadata["idempotency_key"] = JSON::Any.new(metadata.try(&.idempotency_key) || "")
        unless spec.action_class.empty?
          call_metadata["granted_by"] = policy["granted_by"]? || JSON::Any.new("")
          call_metadata["action_authority"] = policy["action_authority"]? || JSON::Any.new({} of String => JSON::Any)
        end
        json.field "metadata", JSON::Any.new(call_metadata)
      end
    end)

    if decision != "auto_approve"
      held = {
        "status"     => JSON::Any.new("held_for_approval"),
        "call_id"    => JSON::Any.new(call_obj.id),
        "risk_class" => JSON::Any.new(spec.risk_class),
        "note"       => JSON::Any.new("This #{spec.risk_class}-risk action was recorded but needs explicit approval before it runs. Tell the user it is waiting for their sign-off."),
      }
      unless spec.action_class.empty?
        authority = policy["action_authority"]?.try(&.as_h) || {} of String => JSON::Any
        held["action_class"] = JSON::Any.new(spec.action_class)
        held["action_authority_reason"] = authority["reason"]? || JSON::Any.new("")
      end
      return held
    end

    call_data = JSON.parse(call_obj.data).as_h
    result = execute_approved_call(graph, call_obj.id, call_data, settings, executed_by: behavior_name)
    approval = CapabilityApproval.new(
      call_obj.id,
      provider_id: provider_id,
      provider_name: spec.provider_name,
      capability_name: spec.capability_name,
      action_class: spec.action_class,
      input_data: input_data,
      credential_ref_name: spec.credential_ref_name,
      frame_id: metadata.try(&.frame_id),
      policy_decision: "auto_approved",
      approver: "gateway_llm_proxy",
      approved_at: now,
      metadata: begin
        m = {"risk_class" => JSON::Any.new(spec.risk_class), "executed" => JSON::Any.new("inline")}
        unless spec.action_class.empty?
          m["granted_by"] = policy["granted_by"]? || JSON::Any.new("")
          m["action_authority"] = policy["action_authority"]? || JSON::Any.new({} of String => JSON::Any)
        end
        m
      end,
    )
    approval_obj = graph.add_object("capability_approval", approval.to_json)
    graph.add_relation(call_obj.id, approval_obj.id, "approved_by")

    output = result["output_data"]?.try(&.as_s?) || ""
    injection_flags = (result["injection_flags"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    if settings.envelope_llm_output? && !output.empty?
      output = Untrusted.wrap_untrusted(output, injection_flags)
    end
    {
      "status"  => result["status"]? || JSON::Any.new(""),
      "call_id" => JSON::Any.new(call_obj.id),
      "output"  => JSON::Any.new(output),
      "error"   => result["error"]? || JSON::Any.new(nil),
    }
  end

  # Runtime-backed pipeline: policy has the same gateway outcome but records
  # the vendor-required authority.decision receipt before capability_call.
  def self._llm_proxy_pipeline(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings, runtime : Chronicle::Runtime(M), provider_id : String, input_data : Hash(String, JSON::Any), metadata : GatewayToolMetadata?) : Hash(String, JSON::Any) forall M
    policy = evaluate_call_policy(
      spec.key, spec.risk_class, spec.action_class, settings,
      runtime: runtime,
      graph: graph,
      actor: metadata.try(&.behavior_name) || "gateway_llm_proxy",
    )
    _llm_proxy_pipeline_with_policy(graph, spec, settings, provider_id, input_data, metadata, policy)
  end

  # Wrap one registered capability as a Crig tool proxy. The gateway's
  # never-offer-to-a-model set and the input-schema requirement are enforced
  # here; the returned Crig::ToolDyn is safe to register in a Crig::ToolSet.
  def self.as_llm_tool(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings? = nil, provider_id : String = "", timeout_seconds : Float64 = 30.0, authority_ceiling : String = "none") : Crig::ToolDyn
    if Untrusted::NEVER_LLM_CALLABLE.includes?(spec.capability_name)
      raise Chronicle::Packs::PackError.new("Capability #{spec.key.inspect} can never be offered to a model: approval resolution is the human half of 'model proposes; runtime disposes'. No allow-list can override this (tool_gateway.untrusted.NEVER_LLM_CALLABLE).")
    end
    unless spec.input_schema_available
      raise Chronicle::Packs::PackError.new("Capability #{spec.key.inspect} has no input_schema, so it cannot be offered to an LLM (the model would see an empty parameter schema and call it with {}). Register it with input_schema_available: true.")
    end

    CrigGatewayTool.new(graph, spec, settings || ToolGatewaySettings.new, provider_id: provider_id, authority_ceiling: authority_ceiling)
  end

  # Bind an LLM proxy to its owning runtime.  This is the vendor's audited
  # construction path: only this form evaluates a declared action class via
  # Runtime#evaluate_capability_authority and therefore emits authority.decision.
  def self.as_llm_tool(graph : Chronicle::GraphProjection, spec : CapabilitySpec, runtime : Chronicle::Runtime(M), settings : ToolGatewaySettings? = nil, provider_id : String = "", timeout_seconds : Float64 = 30.0) : Crig::ToolDyn forall M
    if Untrusted::NEVER_LLM_CALLABLE.includes?(spec.capability_name)
      raise Chronicle::Packs::PackError.new("Capability #{spec.key.inspect} can never be offered to an LLM.")
    end
    unless spec.input_schema_available
      raise Chronicle::Packs::PackError.new("Capability #{spec.key.inspect} has no input_schema, so it cannot be offered to an LLM.")
    end

    RuntimeCrigGatewayTool(M).new(graph, spec, settings || ToolGatewaySettings.new, runtime, provider_id: provider_id)
  end

  # Construction-time Chronicle Tool counterpart for an @[LLMBehavior]. It
  # is deliberately behavior-scoped rather than runtime-registered: the
  # vendor binds these gateway proxies while rebuilding the agentic Chat pack.
  def self.as_runtime_llm_tool(graph : Chronicle::GraphProjection, spec : CapabilitySpec, settings : ToolGatewaySettings? = nil, provider_id : String = "", authority_ceiling : String = "none") : Chronicle::Tool
    if Untrusted::NEVER_LLM_CALLABLE.includes?(spec.capability_name)
      raise Chronicle::Packs::PackError.new("Capability #{spec.key.inspect} can never be offered to a model: approval resolution is the human half of 'model proposes; runtime disposes'. No allow-list can override this (tool_gateway.untrusted.NEVER_LLM_CALLABLE).")
    end
    unless spec.input_schema_available
      raise Chronicle::Packs::PackError.new("Capability #{spec.key.inspect} has no input_schema, so it cannot be offered to an LLM. Register it with input_schema_available: true.")
    end

    gateway_settings = settings || ToolGatewaySettings.new
    Chronicle::Tool.new(
      spec.key,
      spec.description.empty? ? "Gateway capability #{spec.key}." : spec.description,
      false,
      false,
      false,
      nil,
      nil,
      ->(args : String, context : Chronicle::ToolContext) : String {
        input = JSON.parse(args).as_h
        metadata = GatewayToolMetadata.new(
          behavior_name: context.behavior_name,
          frame_id: context.frame_id,
          idempotency_key: context.idempotency_key,
        )
        outcome = _llm_proxy_pipeline(graph, spec, gateway_settings, authority_ceiling, provider_id, input, metadata)
        # Runtime tool events persist `output` as raw JSON. Preserve arbitrary
        # capability output (including the untrusted envelope) as one JSON
        # string value rather than producing invalid event payloads.
        outcome["status"]?.try(&.as_s?) == "held_for_approval" ? outcome.to_json : (outcome["output"]?.try(&.as_s?) || "").to_json
      },
    ) { |_args| "" }
  end

  # Build Crig tool proxies for the given capability keys; unknown keys fail
  # loud with what IS registered. Hand the result to a Crig::ToolSet so an
  # agent tool server can invoke the proxies.
  def self.llm_tools_for(graph : Chronicle::GraphProjection, keys : Array(String), settings : ToolGatewaySettings? = nil, provider_ids : Hash(String, String)? = nil, authority_ceiling : String = "none") : Array(Crig::ToolDyn)
    tools = [] of Crig::ToolDyn
    keys.each do |key|
      spec = get_capability_spec(key)
      if spec.nil?
        registered = registered_capability_keys
        raise Chronicle::Packs::PackError.new("No capability registered under #{key.inspect}. Registered keys: #{registered.empty? ? "(none)" : registered.join(", ")}. Register it first with register_local_capability(provider, capability, fn, input_schema_available: ..., description: ..., risk_class: ...).")
      end
      tools << as_llm_tool(
        graph, spec,
        settings: settings,
        provider_id: (provider_ids || {} of String => String)[spec.provider_name]? || "",
        authority_ceiling: authority_ceiling,
      )
    end
    tools
  end

  def self.runtime_llm_tools_for(graph : Chronicle::GraphProjection, keys : Array(String), settings : ToolGatewaySettings? = nil, provider_ids : Hash(String, String)? = nil, authority_ceiling : String = "none") : Array(Chronicle::Tool)
    keys.map do |key|
      spec = get_capability_spec(key)
      if spec.nil?
        registered = registered_capability_keys
        raise Chronicle::Packs::PackError.new("No capability registered under #{key.inspect}. Registered keys: #{registered.empty? ? "(none)" : registered.join(", ")}.")
      end
      as_runtime_llm_tool(
        graph, spec,
        settings: settings,
        provider_id: (provider_ids || {} of String => String)[spec.provider_name]? || "",
        authority_ceiling: authority_ceiling,
      )
    end
  end
end

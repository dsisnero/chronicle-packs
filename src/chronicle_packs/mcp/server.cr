require "json"
require "set"

module Chronicle::Packs::MCP
  # Inbound MCP — the assistant as an MCP server. Ported from upstream
  # packs/mcp/server.py. Three layers decide what a caller can do:
  #
  #   1. Auth — a bearer token maps to a caller identifier
  #      (MCPSettings.tokens); the identifier resolves to an Identity/Auth
  #      principal whose ROLE is the unit of exposure.
  #   2. Exposure — mcp_exposure graph objects say which surface each role
  #      may see (fail-closed). Rules are edited through the governed
  #      mcp.set_exposure capability.
  #   3. Gateway policy — exposed capabilities keep their risk classes; a
  #      risky inbound call gets held_for_approval, not execution.
  #
  # Every inbound call — allowed or refused — is an mcp_access audit object.
  # This module is pure: MCPGateway.handle_jsonrpc takes a parsed JSON-RPC
  # message + token and returns a response dict (or nil for notifications).
  # Runtime work (chat, memory, capability execution) is injected as
  # callables so the gateway composes with any host.

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%S+00:00")
  end

  # ── auth ────────────────────────────────────────────────────────────────

  # Map a bearer token to {identifier, role, verification} or nil. A valid
  # configured token yields the caller identifier; the identifier's ROLE
  # comes from Identity/Auth when principals are registered. Without
  # principals, unverified_token_role applies (single-user mode). An
  # INVALID or missing token is always anonymous.
  def self.resolve_caller(graph : Chronicle::GraphProjection, token : String?, settings : MCPSettings) : Hash(String, JSON::Any)?
    return nil if token.nil? || !settings.tokens.has_key?(token)
    identifier = settings.tokens[token]

    has_principals = IdentityAuth.principals_registered

    if !has_principals
      role = settings.unverified_token_role
      return nil if role.empty?
      return {
        "identifier"   => JSON::Any.new(identifier),
        "role"         => JSON::Any.new(role),
        "verification" => JSON::Any.new("identity_unverified"),
      }
    end

    principal = IdentityAuth.lookup_principal_fn(graph, identifier)
    return nil if principal.nil? # identity system active + unknown identifier → refuse
    {
      "identifier"   => JSON::Any.new(identifier),
      "role"         => JSON::Any.new(principal["role"]?.try(&.as_s?) || "unknown"),
      "verification" => JSON::Any.new("identity_verified"),
    }
  end

  # ── exposure ────────────────────────────────────────────────────────────

  # Seed the default exposure rules once (idempotent). After seeding the
  # GRAPH is the source of truth — seeding skips any surface that already
  # has a rule object (enabled or not).
  def self.ensure_default_exposures(graph : Chronicle::GraphProjection, settings : MCPSettings) : Nil
    existing = Set(String).new
    graph.objects(type: "mcp_exposure").each do |obj|
      existing.add(JSON.parse(obj.data)["surface"]?.try(&.as_s?) || "")
    end
    settings.default_exposures.each do |surface, roles|
      next if existing.includes?(surface)
      graph.add_object("mcp_exposure", MCPExposure.new(
        surface: surface,
        roles: roles,
        enabled: true,
        note: "default exposure (seeded at startup)",
        updated_at: _now_iso,
        updated_by: "mcp.defaults",
      ).to_json)
    end
  end

  def self._rule_allows(rule : Hash(String, JSON::Any)?, role : String) : Bool?
    return nil if rule.nil?
    enabled = rule["enabled"]?.try(&.as_bool?) || true
    return false unless enabled
    (rule["roles"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_s).includes?(role)
  end

  # Does any enabled exposure rule grant *surface* to *role*? Fail-closed.
  # Per-tool surfaces check their specific rule first (`tool:<key>`); a
  # specific rule — allow or deny — overrides the generic `tools` gate.
  def self.exposure_allows(graph : Chronicle::GraphProjection, surface : String, role : String?) : Bool
    return false if role.nil?
    rules = {} of String => Hash(String, JSON::Any)
    graph.objects(type: "mcp_exposure").each do |obj|
      # Iteration is insertion-ordered: the LATEST rule per surface wins.
      rules[JSON.parse(obj.data)["surface"]?.try(&.as_s?) || ""] = JSON.parse(obj.data).as_h
    end

    if surface.starts_with?("tool:")
      specific = _rule_allows(rules[surface]?, role)
      return specific unless specific.nil?
      return _rule_allows(rules["tools"]?, role) || false
    end
    _rule_allows(rules[surface]?, role) || false
  end

  # Create or update one exposure rule. The executor behind the governed
  # mcp.set_exposure capability — reaching here means policy approved.
  def self.set_exposure_fn(
    graph : Chronicle::GraphProjection,
    surface : String,
    roles : Array(String),
    enabled : Bool = true,
    note : String = "",
    updated_by : String = "",
  ) : Hash(String, JSON::Any)
    existing_id = nil.as(String?)
    graph.objects(type: "mcp_exposure").each do |obj|
      if JSON.parse(obj.data)["surface"]?.try(&.as_s?) == surface
        existing_id = obj.id # keep scanning: LAST rule wins
      end
    end
    data = MCPExposure.new(
      surface: surface,
      roles: roles,
      enabled: enabled,
      note: note,
      updated_at: _now_iso,
      updated_by: updated_by,
    )
    if existing_id
      graph.patch_object(existing_id, data.to_json)
      return {"ok" => JSON::Any.new(true), "exposure_id" => JSON::Any.new(existing_id), "action" => JSON::Any.new("updated")}
    end
    obj = graph.add_object("mcp_exposure", data.to_json)
    {"ok" => JSON::Any.new(true), "exposure_id" => JSON::Any.new(obj.id), "action" => JSON::Any.new("created")}
  end

  # Register `mcp.set_exposure` as a gateway capability. High risk by
  # default → held for owner approval. The agent can PROPOSE changes to its
  # own MCP surface; the decision is the owner's (R4 authority change).
  def self.register_set_exposure_capability(*, risk_class : String = "high") : ToolGateway::CapabilitySpec
    schema = JSON::Any.new({
      "type"       => JSON::Any.new("object"),
      "properties" => JSON::Any.new({
        "surface" => JSON::Any.new({
          "type"        => JSON::Any.new("string"),
          "description" => JSON::Any.new("Surface to change: 'chat', 'memory_search', 'tools', or 'tool:<capability_key>' for one tool."),
        }),
        "roles" => JSON::Any.new({
          "type"        => JSON::Any.new("array"),
          "items"       => JSON::Any.new({"type" => JSON::Any.new("string")}),
          "description" => JSON::Any.new("Principal roles allowed on this surface (e.g. ['owner', 'agent'])."),
        }),
        "enabled" => JSON::Any.new({"type" => JSON::Any.new("boolean"), "default" => JSON::Any.new(true)}),
        "note"    => JSON::Any.new({"type" => JSON::Any.new("string"), "default" => JSON::Any.new(""), "description" => JSON::Any.new("Why this change is needed.")}),
      }),
      "required" => JSON::Any.new([JSON::Any.new("surface"), JSON::Any.new("roles")]),
    })
    executor = ->(input : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
      graph = bound_graph_or_raise
      # The ported gateway handler receives only input_data (no
      # execution_context), so the caller is recorded as the gateway.
      set_exposure_fn(
        graph,
        input["surface"]?.try(&.as_s?) || "",
        (input["roles"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_s),
        input["enabled"]?.try(&.as_bool?) || true,
        input["note"]?.try(&.as_s?) || "",
        updated_by: "gateway",
      )
    }
    ToolGateway.register_local_capability(
      "mcp", "set_exposure", executor,
      input_schema: schema,
      description: "Change which MCP surface (chat / memory_search / tools / tool:<key>) is exposed to which principal roles. High-risk: held for owner approval.",
      risk_class: risk_class,
      # R4: changing who may reach which surface is an authority change.
      action_class: "R4",
    )
  end

  # ── gateway ─────────────────────────────────────────────────────────────

  # Transport-agnostic inbound MCP endpoint over a live runtime graph.
  class MCPGateway
    getter settings : MCPSettings
    @graph_getter : Proc(Chronicle::GraphProjection)
    @chat_fn : Proc(String, String, String?, Hash(String, JSON::Any))?
    @memory_fn : Proc(String, String, Int32, Array(Hash(String, JSON::Any)))?
    @gw_settings : ToolGateway::ToolGatewaySettings?

    def initialize(
      @graph_getter : Proc(Chronicle::GraphProjection),
      @settings : MCPSettings,
      *,
      @chat_fn : Proc(String, String, String?, Hash(String, JSON::Any))? = nil,
      @memory_fn : Proc(String, String, Int32, Array(Hash(String, JSON::Any)))? = nil,
      @gw_settings : ToolGateway::ToolGatewaySettings? = nil,
    )
    end

    # ── audit ────────────────────────────────────────────────────────────

    def _record_access(graph : Chronicle::GraphProjection, method : String, surface : String, caller : Hash(String, JSON::Any)?, allowed : Bool, reason : String) : Nil
      graph.add_object("mcp_access", MCPAccess.new(
        method: method,
        surface: surface,
        caller: caller.try { |caller_data| caller_data["identifier"]?.try(&.as_s?) } || "",
        role: caller.try { |caller_data| caller_data["role"]?.try(&.as_s?) },
        allowed: allowed,
        reason: reason,
        at: MCP._now_iso,
      ).to_json)
    rescue
    end

    # ── tool catalog ─────────────────────────────────────────────────────

    def _visible_tools(graph : Chronicle::GraphProjection, role : String?) : Array(Hash(String, JSON::Any))
      tools = [] of Hash(String, JSON::Any)
      if MCP.exposure_allows(graph, "chat", role) && !@chat_fn.nil?
        tools << {
          "name"        => JSON::Any.new("chat"),
          "description" => JSON::Any.new("Send a message to this assistant and get its reply. The full pipeline applies: identity, memory, persona, reply gating, and its own governed tool use."),
          "inputSchema" => JSON::Any.new({
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "message"    => JSON::Any.new({"type" => JSON::Any.new("string"), "description" => JSON::Any.new("The message.")}),
              "session_id" => JSON::Any.new({"type" => JSON::Any.new("string"), "description" => JSON::Any.new("Continue an earlier session.")}),
            }),
            "required" => JSON::Any.new([JSON::Any.new("message")]),
          }),
        }
      end
      if MCP.exposure_allows(graph, "memory_search", role) && !@memory_fn.nil?
        tools << {
          "name"        => JSON::Any.new("memory_search"),
          "description" => JSON::Any.new("Search this assistant's long-term memory. Results are scoped to YOUR identity — you see your memories and shared/global ones, never another user's."),
          "inputSchema" => JSON::Any.new({
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "query" => JSON::Any.new({"type" => JSON::Any.new("string")}),
              "top_k" => JSON::Any.new({"type" => JSON::Any.new("integer"), "default" => JSON::Any.new(5)}),
            }),
            "required" => JSON::Any.new([JSON::Any.new("query")]),
          }),
        }
      end
      if MCP.exposure_allows(graph, "catalog", role)
        tools << {
          "name"        => JSON::Any.new("catalog_search"),
          "description" => JSON::Any.new("List the capabilities YOU can reach through this assistant, with risk class, origin (native vs MCP-derived), and whether a call will be held for owner approval. Scoped to your role: capabilities you cannot reach are not listed."),
          "inputSchema" => JSON::Any.new({
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "query" => JSON::Any.new({"type" => JSON::Any.new("string"), "description" => JSON::Any.new("Substring filter (optional).")}),
            }),
          }),
        }
      end
      @settings.expose_capabilities.each do |key|
        next unless MCP.exposure_allows(graph, "tool:#{key}", role)
        spec = ToolGateway.get_capability_spec(key)
        next if spec.nil?
        input_schema = spec.input_schema
        next if input_schema.nil?
        tools << {
          "name"        => JSON::Any.new(key.gsub(".", "__")), # MCP tool-name charset
          "description" => JSON::Any.new("#{spec.description} [risk: #{spec.risk_class}; may be held for owner approval]"),
          "inputSchema" => input_schema,
        }
      end
      tools
    end

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _caller_catalog surface/capability branches
    def _caller_catalog(graph : Chronicle::GraphProjection, caller : Hash(String, JSON::Any), query : String = "") : Array(Hash(String, JSON::Any))
      role = caller["role"]?.try(&.as_s?)
      gw = @gw_settings || ToolGateway::ToolGatewaySettings.new
      entries = [] of Hash(String, JSON::Any)
      if MCP.exposure_allows(graph, "chat", role) && !@chat_fn.nil?
        entries << {"key" => JSON::Any.new("chat"), "kind" => JSON::Any.new("surface"), "risk_class" => JSON::Any.new("low"), "origin" => JSON::Any.new("native"), "held_on_call" => JSON::Any.new(false), "description" => JSON::Any.new("Converse with the assistant.")}
      end
      if MCP.exposure_allows(graph, "memory_search", role) && !@memory_fn.nil?
        entries << {"key" => JSON::Any.new("memory_search"), "kind" => JSON::Any.new("surface"), "risk_class" => JSON::Any.new("low"), "origin" => JSON::Any.new("native"), "held_on_call" => JSON::Any.new(false), "description" => JSON::Any.new("Search your memories.")}
      end
      @settings.expose_capabilities.each do |key|
        next unless MCP.exposure_allows(graph, "tool:#{key}", role)
        spec = ToolGateway.get_capability_spec(key)
        next if spec.nil?
        entries << {
          "key"          => JSON::Any.new(key),
          "kind"         => JSON::Any.new("capability"),
          "risk_class"   => JSON::Any.new(spec.risk_class),
          "origin"       => JSON::Any.new(spec.origin),
          "held_on_call" => JSON::Any.new(ToolGateway.decide_policy(spec.risk_class, gw) == "hold"),
          "description"  => JSON::Any.new(spec.description),
        }
      end
      if !query.empty?
        q = query.downcase
        entries = entries.select { |entry| (entry["key"]?.try(&.as_s?) || "").downcase.includes?(q) || (entry["description"]?.try(&.as_s?) || "").downcase.includes?(q) }
      end
      entries.sort_by! { |entry| entry["key"]?.try(&.as_s?) || "" }
      entries
    end

    # ── governed capability call ─────────────────────────────────────────

    # Run an exposed capability through the gateway: record → policy →
    # execute-or-hold. Inbound capabilities and the assistant's own tool
    # use share one governance path.
    def _call_capability(graph : Chronicle::GraphProjection, key : String, arguments : Hash(String, JSON::Any), caller : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      spec = ToolGateway.get_capability_spec(key)
      if spec.nil?
        return {"error" => JSON::Any.new("capability #{key.inspect} is not registered")}
      end
      gw = @gw_settings || ToolGateway::ToolGatewaySettings.new
      decision = ToolGateway.decide_policy(spec.risk_class, gw)
      now = MCP._now_iso
      caller_ref = caller["identifier"]?.try(&.as_s?) || ""

      call = graph.add_object("capability_call", ToolGateway::CapabilityCall.new(
        provider_id: "",
        provider_name: spec.provider_name,
        capability_name: spec.capability_name,
        input_data: arguments,
        credential_ref_name: spec.credential_ref_name,
        credential_ref_id: nil,
        risk_class: ToolGateway::RiskClass.parse?(spec.risk_class) || ToolGateway::RiskClass::Medium,
        action_class: spec.action_class,
        status: decision == "auto_approve" ? ToolGateway::CallStatus::Approved : ToolGateway::CallStatus::PolicyChecking,
        proposed_by: "mcp:#{caller_ref}",
        frame_id: nil,
        proposed_at: now,
        metadata: {"initiated_by" => JSON::Any.new("mcp_inbound"), "caller_role" => caller["role"]? || JSON::Any.new(nil)},
      ).to_json)

      if decision == "hold"
        return {
          "status"  => JSON::Any.new("held_for_approval"),
          "call_id" => JSON::Any.new(call.id),
          "note"    => JSON::Any.new("This #{spec.risk_class}-risk capability was recorded and is waiting for the owner's approval."),
        }
      end

      call_data = JSON.parse(call.data).as_h
      result = ToolGateway.execute_approved_call(graph, call.id, call_data, gw, executed_by: "mcp:#{caller_ref}")
      graph.add_object("capability_approval", ToolGateway::CapabilityApproval.new(
        call.id,
        provider_id: "",
        provider_name: spec.provider_name,
        capability_name: spec.capability_name,
        action_class: spec.action_class,
        input_data: arguments,
        frame_id: nil,
        policy_decision: "auto_approved",
        approver: "gateway_mcp_inbound",
        approved_at: now,
        metadata: {"risk_class" => JSON::Any.new(spec.risk_class), "executed" => JSON::Any.new("inline")},
      ).to_json)
      {
        "status"  => result["status"]? || JSON::Any.new(""),
        "call_id" => JSON::Any.new(call.id),
        "output"  => result["output_data"]? || JSON::Any.new(""),
        "error"   => result["error"]? || JSON::Any.new(nil),
      }
    end

    # ── JSON-RPC ──────────────────────────────────────────────────────────

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream handle_jsonrpc auth/exposure branches
    def handle_jsonrpc(message : Hash(String, JSON::Any), token : String?) : Hash(String, JSON::Any)?
      if message["jsonrpc"]?.try(&.as_s?) != "2.0"
        return self.class._error(nil, MCPConstants::INVALID_REQUEST, "not a JSON-RPC 2.0 message")
      end

      method = message["method"]?.try(&.as_s?) || ""
      msg_id = message["id"]?
      params = message["params"]?.try(&.as_h?) || {} of String => JSON::Any
      graph = @graph_getter.call
      caller = MCP.resolve_caller(graph, token, @settings)

      # Handshake is unauthenticated (a client must be able to introduce
      # itself), but carries no data and exposes nothing.
      case method
      when "initialize"
        self.class._result(msg_id, {
          "protocolVersion" => JSON::Any.new(params["protocolVersion"]?.try(&.as_s?) || MCPConstants::PROTOCOL_VERSION),
          "capabilities"    => JSON::Any.new({"tools" => JSON::Any.new({} of String => JSON::Any)}),
          "serverInfo"      => JSON::Any.new(MCPConstants::SERVER_INFO.transform_values { |value| JSON::Any.new(value) }),
        })
      when "notifications/initialized"
        nil
      when "ping"
        self.class._result(msg_id, {} of String => JSON::Any)
      when "tools/list"
        if caller.nil? && token
          _record_access(graph, method, "", nil, false, "invalid token")
          self.class._error(msg_id, MCPConstants::UNAUTHORIZED, "invalid token")
        else
          tools = _visible_tools(graph, caller.try { |caller_data| caller_data["role"]?.try(&.as_s?) })
          _record_access(graph, method, "", caller, true, "#{tools.size} tools visible")
          self.class._result(msg_id, {"tools" => JSON::Any.new(tools.map { |tool| JSON::Any.new(tool) })})
        end
      when "tools/call"
        name = params["name"]?.try(&.as_s?) || ""
        arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any
        if caller.nil?
          reason = token ? "invalid token" : "no token"
          _record_access(graph, method, name, nil, false, reason)
          self.class._error(msg_id, MCPConstants::UNAUTHORIZED, "authentication required (#{reason})")
        else
          _dispatch_call(graph, msg_id, name, arguments, caller)
        end
      else
        self.class._error(msg_id, MCPConstants::METHOD_NOT_FOUND, "method #{method.inspect} not supported")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _dispatch_call surface/capability branches
    def _dispatch_call(graph : Chronicle::GraphProjection, msg_id : JSON::Any?, name : String, arguments : Hash(String, JSON::Any), caller : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      role = caller["role"]?.try(&.as_s?)
      caller_ref = caller["identifier"]?.try(&.as_s?) || ""

      if name == "chat"
        chat_fn = @chat_fn
        if chat_fn.nil? || !MCP.exposure_allows(graph, "chat", role)
          _record_access(graph, "tools/call", "chat", caller, false, "chat not exposed to role")
          return self.class._error(msg_id, MCPConstants::FORBIDDEN, "chat is not exposed to you")
        end
        _record_access(graph, "tools/call", "chat", caller, true, "ok")
        reply = chat_fn.call(arguments["message"]?.try(&.as_s?) || "", caller_ref, arguments["session_id"]?.try(&.as_s?))
        meta = {} of String => JSON::Any
        if session_id = reply["session_id"]?
          meta["session_id"] = session_id
        end
        return self.class._tool_text(msg_id, reply["content"]?.try(&.as_s?) || "", meta)
      end

      if name == "memory_search"
        memory_fn = @memory_fn
        if memory_fn.nil? || !MCP.exposure_allows(graph, "memory_search", role)
          _record_access(graph, "tools/call", "memory_search", caller, false, "memory_search not exposed to role")
          return self.class._error(msg_id, MCPConstants::FORBIDDEN, "memory_search is not exposed to you")
        end
        _record_access(graph, "tools/call", "memory_search", caller, true, "ok")
        results = memory_fn.call(arguments["query"]?.try(&.as_s?) || "", caller_ref, arguments["top_k"]?.try(&.as_i?) || 5)
        return self.class._tool_text(msg_id, {"results" => JSON::Any.new(results.map { |row| JSON::Any.new(row) })}.to_json)
      end

      if name == "catalog_search"
        if !MCP.exposure_allows(graph, "catalog", role)
          _record_access(graph, "tools/call", "catalog", caller, false, "catalog not exposed to role")
          return self.class._error(msg_id, MCPConstants::FORBIDDEN, "catalog is not exposed to you")
        end
        _record_access(graph, "tools/call", "catalog", caller, true, "ok")
        entries = _caller_catalog(graph, caller, arguments["query"]?.try(&.as_s?) || "")
        return self.class._tool_text(msg_id, {"count" => JSON::Any.new(entries.size), "capabilities" => JSON::Any.new(entries.map { |entry| JSON::Any.new(entry) })}.to_json)
      end

      # Exposed gateway capability (tool name uses __ for the dot).
      key = name.gsub("__", ".")
      if @settings.expose_capabilities.includes?(key)
        if !MCP.exposure_allows(graph, "tool:#{key}", role)
          _record_access(graph, "tools/call", "tool:#{key}", caller, false, "tool not exposed to role")
          return self.class._error(msg_id, MCPConstants::FORBIDDEN, "#{key} is not exposed to you")
        end
        _record_access(graph, "tools/call", "tool:#{key}", caller, true, "ok")
        outcome = _call_capability(graph, key, arguments, caller)
        is_error = !(outcome["error"]?.try(&.as_s?) || "").empty?
        return self.class._tool_text(msg_id, outcome.to_json, is_error: is_error)
      end

      _record_access(graph, "tools/call", name, caller, false, "unknown tool")
      self.class._error(msg_id, MCPConstants::METHOD_NOT_FOUND, "unknown tool #{name.inspect}")
    end

    # ── JSON-RPC helpers ──────────────────────────────────────────────────

    def self._result(msg_id : JSON::Any?, result : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      {"jsonrpc" => JSON::Any.new("2.0"), "id" => msg_id ? msg_id : JSON::Any.new(nil), "result" => JSON::Any.new(result)}
    end

    def self._error(msg_id : JSON::Any?, code : Int32, message : String) : Hash(String, JSON::Any)
      {"jsonrpc" => JSON::Any.new("2.0"), "id" => msg_id ? msg_id : JSON::Any.new(nil), "error" => JSON::Any.new({"code" => JSON::Any.new(code), "message" => JSON::Any.new(message)})}
    end

    def self._tool_text(msg_id : JSON::Any?, text : String, meta : Hash(String, JSON::Any)? = nil, is_error : Bool = false) : Hash(String, JSON::Any)
      result = {"content" => JSON::Any.new([JSON::Any.new({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)})]), "isError" => JSON::Any.new(is_error)}
      if meta && !meta.empty?
        result["_meta"] = JSON::Any.new(meta)
      end
      {"jsonrpc" => JSON::Any.new("2.0"), "id" => msg_id ? msg_id : JSON::Any.new(nil), "result" => JSON::Any.new(result)}
    end
  end
end

require "json"

module Chronicle::Packs::MCP
  # Outbound MCP → Tool Gateway registration. Ported from upstream
  # packs/mcp/registry.py. connect_and_register discovers one MCP server's
  # tools and registers each as a Tool Gateway capability — every MCP tool
  # arrives pre-governed: policy-checked (high risk by default), action-
  # classed R3 by default (ADR 0016, never derived from the risk label),
  # recorded, sanitized, and injection-scanned through the same gateway path.
  # Capability keys are `mcp_<server>.<tool>`. Discovery needs a live
  # connection, so the network edge is here (called by the host at startup),
  # not in a behavior; fixtures inject a fake client.

  # JSON Schema type → Crystal/JSON shape for MCP tool inputSchemas. The
  # port keeps ordinary JSON Schema objects (the MCP server revalidates on
  # its side); the schema is for the LLM's benefit, not enforcement.
  def self.schema_model_from_json_schema(model_name : String, schema : JSON::Any?) : JSON::Any
    schema_h = schema.try(&.as_h?) || {} of String => JSON::Any
    properties = schema_h["properties"]?.try(&.as_h?) || {} of String => JSON::Any
    required = (schema_h["required"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_s)

    result_properties = {} of String => JSON::Any
    properties.each do |prop_name, prop_schema|
      prop_h = prop_schema.try(&.as_h?) || {} of String => JSON::Any
      type = prop_h["type"]?.try(&.as_s?) || ""
      json_type = type.in?({"string", "number", "integer", "boolean", "array", "object"}) ? type : nil
      entry = {} of String => JSON::Any
      entry["type"] = JSON::Any.new(json_type || "string")
      if description = prop_h["description"]?
        entry["description"] = description
      end
      if !required.includes?(prop_name)
        if default = prop_h["default"]?
          entry["default"] = default
        end
      end
      result_properties[prop_name] = JSON::Any.new(entry)
    end

    JSON::Any.new({
      "type"       => JSON::Any.new("object"),
      "properties" => JSON::Any.new(result_properties),
      "required"   => JSON::Any.new(required.map { |name| JSON::Any.new(name) }),
    })
  end

  # Discover one MCP server's tools and register them as capabilities.
  # Returns the registered capability keys (`mcp_<server>.<tool>`).
  def self.connect_and_register(
    server_name : String,
    client : MCPClient,
    *,
    graph : Chronicle::GraphProjection? = nil,
    default_risk : String = "high",
    tool_risk_overrides : Hash(String, String)? = nil,
    default_action_class : String = "R3",
    tool_action_class_overrides : Hash(String, String)? = nil,
    credential_ref_name : String? = nil,
  ) : Array(String)
    overrides = tool_risk_overrides || {} of String => String
    action_overrides = tool_action_class_overrides || {} of String => String
    server_info = client.handshake
    tools = client.list_tools

    registered = [] of String
    provider_name = "mcp_#{server_name}"
    tools.each do |tool_def|
      tool_name = tool_def["name"]?.try(&.as_s?) || ""
      next if tool_name.empty?
      risk = overrides[tool_name]? || default_risk
      action = action_overrides[tool_name]? || default_action_class
      schema = schema_model_from_json_schema("MCP_#{server_name}_#{tool_name}_Input", tool_def["inputSchema"]?)

      client_obj = client
      executor = ->(input : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        input_data = input.dup
        input_data.delete("execution_context")
        text, is_error = client_obj.call_tool_text(tool_name, input_data)
        if is_error
          raise RuntimeError.new("MCP tool #{tool_name.inspect} returned an error: #{text[0, 500]}")
        end
        {"text" => JSON::Any.new(text), "server" => JSON::Any.new(server_name), "tool" => JSON::Any.new(tool_name)}
      }

      spec = ToolGateway.register_local_capability(
        provider_name, tool_name, executor,
        input_schema: schema,
        description: "[MCP:#{server_name}] #{tool_def["description"]?.try(&.as_s?) || ""}".strip,
        risk_class: risk,
        action_class: action,
        credential_ref_name: credential_ref_name,
        origin: "mcp:#{server_name}",
      )
      registered << spec.key
    end

    if graph
      begin
        graph.add_object("mcp_server", MCPServer.new(
          name: server_name,
          direction: "outbound",
          server_info: server_info,
          tool_names: tools.map { |tool_def| tool_def["name"]?.try(&.as_s?) || "" },
          capability_keys: registered,
          default_risk: default_risk,
          risk_overrides: overrides,
          default_action_class: default_action_class,
          action_class_overrides: action_overrides,
          status: "connected",
          connected_at: _now_iso,
        ).to_json)
      rescue
        # graph audit is best-effort; the registry is the source of truth
      end
    end

    registered
  end

  # Connect every server in MCPSettings.servers (the host-startup path).
  # Servers that fail to connect are recorded (status='unreachable') and
  # skipped — one broken MCP server must not take down the assistant.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream per-server failure isolation
  def self.register_configured_servers(settings : MCPSettings, graph : Chronicle::GraphProjection? = nil) : Hash(String, Array(String))
    results = {} of String => Array(String)
    settings.servers.each do |server|
      name = server["name"]?.try(&.as_s?) || ""
      next if name.empty?
      begin
        headers = ((server["headers"]?.try(&.as_h?) || {} of String => JSON::Any).transform_values(&.as_s))
        command = server["command"]?.try(&.as_a?) ? server["command"].as_a.map(&.as_s) : nil
        client = make_client(
          server["transport"]?.try(&.as_s?) || "http",
          url: server["url"]?.try(&.as_s?) || "",
          command: command,
          headers: headers,
        )
        results[name] = connect_and_register(
          name,
          client,
          graph: graph,
          default_risk: server["default_risk"]?.try(&.as_s?) || settings.default_tool_risk,
          tool_risk_overrides: server["tool_risk_overrides"]?.try(&.as_h?) ? server["tool_risk_overrides"].as_h.transform_values(&.as_s) : nil,
          default_action_class: server["default_action_class"]?.try(&.as_s?) || settings.default_tool_action_class,
          tool_action_class_overrides: server["tool_action_class_overrides"]?.try(&.as_h?) ? server["tool_action_class_overrides"].as_h.transform_values(&.as_s) : nil,
          credential_ref_name: server["credential_ref_name"]?.try(&.as_s?),
        )
      rescue ex
        results[name] = [] of String
        if graph
          begin
            graph.add_object("mcp_server", MCPServer.new(
              name: name,
              direction: "outbound",
              status: "unreachable",
              error: "#{ex.class}: #{ex.message}",
              connected_at: _now_iso,
            ).to_json)
          rescue
          end
        end
      end
    end
    results
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%S+00:00")
  end
end

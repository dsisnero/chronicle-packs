require "json"

module Chronicle::Packs::Composio
  # Gateway registrations for the thin Composio route. Ported from upstream
  # packs/composio/capabilities.py.

  # Parameters for composio.connections.link.
  record LinkServiceInput,
    user_id : String,
    service : String,
    callback_url : String

  # Parameters for composio.connections.status.
  record ConnectionStatusInput,
    user_id : String,
    service : String,
    limit : Int32 = 25

  # Create a hosted Composio Connect Link for one explicitly selected service.
  def self._link_service(input_data : Hash(String, JSON::Any), *, api_key_env : String = "COMPOSIO_API_KEY") : Hash(String, JSON::Any)
    user_id = input_data["user_id"]?.try(&.as_s?) || ""
    service = input_data["service"]?.try(&.as_s?) || ""
    callback_url = input_data["callback_url"]?.try(&.as_s?) || ""
    response = composio_transport(api_key_env: api_key_env).authorize(
      user_id: user_id, toolkit: service, callback_url: callback_url
    )
    safe = store_redirect(response["id"]?.try(&.as_s?) || "", response["redirect_url"]?.try(&.as_s?) || "")
    result = {"ok" => JSON::Any.new(true), "service" => JSON::Any.new(service), "status" => response["status"]? || JSON::Any.new(nil)} of String => JSON::Any
    safe.each { |key, value| result[key] = value }
    result
  end

  # Read connection status for one selected Composio service.
  def self._connection_status(input_data : Hash(String, JSON::Any), *, api_key_env : String = "COMPOSIO_API_KEY") : Hash(String, JSON::Any)
    user_id = input_data["user_id"]?.try(&.as_s?) || ""
    service = input_data["service"]?.try(&.as_s?) || ""
    limit = input_data["limit"]?.try(&.as_i?) || 25
    rows = composio_transport(api_key_env: api_key_env).list_connections(
      user_id: user_id, toolkit: service, limit: limit
    )
    {
      "ok"          => JSON::Any.new(true),
      "service"     => JSON::Any.new(service),
      "connections" => JSON::Any.new(rows.map { |row| JSON::Any.new(connection_summary(row)) }),
    }
  end

  # Register both Composio route capabilities on the gateway.
  def self.register_composio_capabilities(*, api_key_env : String = "COMPOSIO_API_KEY") : {ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec}
    link_spec = ToolGateway.register_local_capability(
      "composio", "connections.link",
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) { _link_service(input_data, api_key_env: api_key_env) },
      description: "Create a hosted Composio Connect Link for one explicitly selected service.",
      risk_class: "high",
      action_class: "R4",
    )
    status_spec = ToolGateway.register_local_capability(
      "composio", "connections.status",
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) { _connection_status(input_data, api_key_env: api_key_env) },
      description: "Read connection status for one selected Composio service.",
      risk_class: "low",
      action_class: "R0",
    )
    {link_spec, status_spec}
  end
end

require "json"
require "digest"

module Chronicle::Packs::ConnectorControl
  # Service-neutral connector maintenance request registry. Ported from
  # upstream packs/connector_control/maintenance.py.

  alias MaintenanceHandler = Proc(Chronicle::GraphProjection, Chronicle::GraphObject, Chronicle::GraphObject, Hash(String, JSON::Any))

  # Handlers registry, nested so the DSL pack macro (which assumes direct
  # module constants are types) can enumerate the surface.
  module MaintenanceRegistry
    HANDLERS = {} of String => MaintenanceHandler
  end

  # Merge-append patch: chronicle's patch_object replaces the whole object.
  def self._patch(graph : Chronicle::GraphProjection, target : String, updates : Hash(String, JSON::Any)) : Nil
    current = graph.get_object(target)
    return if current.nil?

    data = JSON.parse(current.data).as_h
    updates.each { |key, value| data[key] = value }
    graph.patch_object(target, JSON::Any.new(data).to_json)
  end

  def self._stable_id(prefix : String, *parts) : String
    raw = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(raw)[0, 24]}"
  end

  def self.register_connector_maintenance_handler(service : String, handler : MaintenanceHandler, replace : Bool = true) : Nil
    key = service.strip.downcase
    raise ArgumentError.new("service is required") if key.empty?
    if MaintenanceRegistry::HANDLERS.has_key?(key) && !replace
      raise ArgumentError.new("maintenance handler already registered for #{key.inspect}")
    end
    MaintenanceRegistry::HANDLERS[key] = handler
  end

  def self.clear_connector_maintenance_handlers : Nil
    MaintenanceRegistry::HANDLERS.clear
  end

  def self.unregister_connector_maintenance_handler(service : String) : Nil
    MaintenanceRegistry::HANDLERS.delete(service.strip.downcase)
  end

  # Request bounded maintenance through a connector's service adapter.
  # The single active manual-refresh-capable binding for a surface, or raise.
  def self._refresh_binding(graph : Chronicle::GraphProjection, source_surface_id : String) : {Chronicle::GraphObject, Hash(String, JSON::Any)}
    bindings = graph.objects(type: "connector_surface_binding").select { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == source_surface_id }
    raise Chronicle::Packs::PackError.new("expected one connector binding for #{source_surface_id.inspect}") unless bindings.size == 1
    binding = bindings.first
    data = JSON.parse(binding.data).as_h
    raise Chronicle::Packs::PackError.new("connector is not active; reconnect before refreshing") unless data["status"]?.try(&.as_s?) == "active"
    raise Chronicle::Packs::PackError.new("connector does not currently permit manual refresh") unless data["manual_refresh_available"]?.try(&.as_bool?) || false
    {binding, data}
  end

  # An already-queued/running observation for the surface, if any.
  def self._active_refresh_run(graph : Chronicle::GraphProjection, source_surface_id : String) : Chronicle::GraphObject?
    graph.objects(type: "connector_run_observation").find do |obj|
      data = JSON.parse(obj.data)
      data["source_surface_id"]?.try(&.as_s?) == source_surface_id && data["state"]?.try(&.as_s?).in?({"queued", "running"})
    end
  end

  # Dispatch the registered handler and record accept/fail on the request.
  def self._dispatch_maintenance(graph : Chronicle::GraphProjection, request_obj : Chronicle::GraphObject, binding : Chronicle::GraphObject, handler : MaintenanceHandler) : Hash(String, JSON::Any)
    begin
      result = handler.call(graph, binding, request_obj)
    rescue ex
      error = "#{ex.class}: #{ex}"[0, 500]
      _patch(graph, request_obj.id, {"status" => JSON::Any.new("failed"), "error" => JSON::Any.new(error)})
      return {"ok" => JSON::Any.new(false), "created" => JSON::Any.new(true), "request_id" => JSON::Any.new(request_obj.id), "error" => JSON::Any.new(error)}
    end
    run_id_value = result["run_id"]?.try(&.as_s?) || result["domain_run_id"]?.try(&.as_s?)
    accepted_run_id = run_id_value.nil? || run_id_value.empty? ? nil : run_id_value
    _patch(graph, request_obj.id, {"status" => JSON::Any.new("accepted"), "domain_run_id" => accepted_run_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil)})
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "request_id" => JSON::Any.new(request_obj.id), "domain_run_id" => accepted_run_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil), "service_result" => JSON::Any.new(result)}
  end

  # Request bounded maintenance through a connector's service adapter.
  def self.request_connector_refresh_fn(graph : Chronicle::GraphProjection, source_surface_id : String, requested_by : String = "owner") : Hash(String, JSON::Any)
    binding, binding_data = _refresh_binding(graph, source_surface_id)
    if active = _active_refresh_run(graph, source_surface_id)
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "already_running" => JSON::Any.new(true), "domain_run_id" => JSON.parse(active.data)["domain_run_id"]? || JSON::Any.new(nil)}
    end

    prior = graph.objects(type: "connector_maintenance_request").select { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == source_surface_id }
    request = ConnectorMaintenanceRequest.new(
      _stable_id("connector_refresh", source_surface_id, prior.size + 1),
      source_surface_id, binding_data["service"]?.try(&.as_s?) || "", binding_data["account_ref"]?.try(&.as_s?) || "",
      requested_by, metadata: {"binding_id" => JSON::Any.new(binding.id)})
    request_obj = graph.add_object("connector_maintenance_request", request.to_json)
    handler = MaintenanceRegistry::HANDLERS[(binding_data["service"]?.try(&.as_s?) || "").downcase]?
    if handler.nil?
      _patch(graph, request_obj.id, {"status" => JSON::Any.new("failed"), "error" => JSON::Any.new("maintenance_handler_unavailable")})
      return {"ok" => JSON::Any.new(false), "created" => JSON::Any.new(true), "request_id" => JSON::Any.new(request_obj.id), "error" => JSON::Any.new("maintenance_handler_unavailable")}
    end
    _dispatch_maintenance(graph, request_obj, binding, handler)
  end
end

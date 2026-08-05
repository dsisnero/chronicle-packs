require "json"

module Chronicle::Packs::ConnectorControl
  # Seed the versioned cross-family operational release policy and project
  # source lifecycle into connector bindings. Ported from upstream
  # packs/connector_control/behaviors.py.

  # Seed the default operational policy once per store.
  @[Chronicle::Packs::Annotations::Behavior(name: "seed_connector_operational_policy", on: ["pack.loaded"], where: {"name" => "connector_control"}, creates: ["connector_operational_policy"])]
  def seed_connector_operational_policy(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ConnectorControlSettings) : Nil
    existing = graph.objects(type: "connector_operational_policy").any? { |obj| JSON.parse(obj.data)["policy_identity"]?.try(&.as_s?) == Policy::OPERATIONAL_POLICY_ID }
    return if existing

    graph.add_object("connector_operational_policy", JSON::Any.new(operational_policy_payload).to_json)
  end

  # Map a source lifecycle status onto connector binding status.
  def self._binding_status_for(status : String) : String?
    case status
    when "connected"       then "active"
    when "stale", "failed" then "stale"
    when "revoked"         then "revoked"
    else
      nil
    end
  end

  # Project source lifecycle changes onto matching connector bindings.
  @[Chronicle::Packs::Annotations::Behavior(name: "project_source_lifecycle_to_connector_binding", on: ["source.lifecycle_changed"])]
  def project_source_lifecycle_to_connector_binding(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ConnectorControlSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    surface_id = payload["surface_id"]?.try(&.as_s?) || ""
    status = payload["status"]?.try(&.as_s?) || ""
    binding_status = _binding_status_for(status)
    return if surface_id.empty? || binding_status.nil?

    graph.objects(type: "connector_surface_binding").each do |binding|
      data = JSON.parse(binding.data).as_h
      if data["source_surface_id"]?.try(&.as_s?) == surface_id && data["status"]?.try(&.as_s?) != binding_status
        data["status"] = JSON::Any.new(binding_status)
        _patch(graph, binding.id, data)
      end
    end
  end
end

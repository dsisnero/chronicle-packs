require "json"

module Chronicle::Packs::Gmail
  # Gmail implementation of the neutral connector maintenance request. Ported
  # from upstream packs/gmail/maintenance.py.

  def self.request_gmail_maintenance_fn(
    graph : Chronicle::GraphProjection,
    binding : Chronicle::GraphObject,
    request : Chronicle::GraphObject,
  ) : Hash(String, JSON::Any)
    surface_id = JSON.parse(binding.data)["source_surface_id"]?.try(&.as_s?) || ""
    prior_runs = graph.objects(type: "gmail_sync_run").select { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == surface_id }
    if prior_runs.empty?
      raise Chronicle::Packs::PackError.new("Gmail requires one completed backfill before history polling")
    end
    prior = prior_runs.last
    prior_data = JSON.parse(prior.data).as_h
    cursors = graph.objects(type: "backfill_cursor").select { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == surface_id }
    watermark_ref = cursors.empty? ? "" : JSON.parse(cursors.last.data)["watermark_ref"]?.try(&.as_s?) || ""
    unless watermark_ref.starts_with?("history:")
      raise Chronicle::Packs::PackError.new("Gmail history watermark is unavailable; reconnect/re-explore")
    end
    request_gmail_poll_fn(
      graph,
      source_surface_id: surface_id,
      account_ref: JSON.parse(binding.data)["account_ref"]?.try(&.as_s?) || prior_data["account_ref"]?.try(&.as_s?) || "",
      user_id: prior_data["user_id"]?.try(&.as_s?) || "",
      connected_account_id: prior_data["connected_account_id"]?.try(&.as_s?) || "",
      start_history_id: watermark_ref.split(":", 2)[1]? || "",
      max_messages: 100,
      route: JSON.parse(binding.data)["active_route"]?.try(&.as_s?) || "composio",
    )
  end

  def self.register_gmail_maintenance : Nil
    ConnectorControl.register_connector_maintenance_handler(
      "gmail",
      ->(graph : Chronicle::GraphProjection, binding : Chronicle::GraphObject, request : Chronicle::GraphObject) : Hash(String, JSON::Any) {
        request_gmail_maintenance_fn(graph, binding, request)
      }
    )
  end
end

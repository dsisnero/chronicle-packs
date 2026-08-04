require "json"
require "time"

module Chronicle::Packs::Secrets
  # Secrets behaviors. Ported from upstream packs/secrets/behaviors.py.
  # They handle graph-visible tracking only — never actual secret values.

  def self._utc_now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Record a SecretUsageEvent when a CredentialRef is registered.
  @[Chronicle::Packs::Annotations::Behavior(name: "secret_usage_recorder", on: ["object.created"], where: {"type" => "credential_ref"}, creates: ["secret_usage_event"])]
  def secret_usage_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SecretsSettings) : Nil
    return if !settings.record_usage_events?

    payload = JSON.parse(event.payload)
    ref_name = payload["data"]?.try(&.["name"]?.try(&.as_s?)) || ""
    return if ref_name.empty?

    graph.add_object("secret_usage_event", JSON.build do |json|
      json.object do
        json.field "credential_ref_name", ref_name
        json.field "behavior_name", "secret_usage_recorder"
        json.field "resolved", false
        json.field "timestamp", _utc_now_iso
        json.field "metadata", {"event_type" => JSON::Any.new("registered")}
      end
    end)
  end

  # Update CredentialRef stats when a resolution usage event is created.
  @[Chronicle::Packs::Annotations::Behavior(name: "credential_resolution_recorder", on: ["object.created"], where: {"type" => "secret_usage_event"})]
  def credential_resolution_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SecretsSettings) : Nil
    payload = JSON.parse(event.payload)
    data = payload["data"]?
    return if data.nil?

    event_type = data["metadata"]?.try(&.["event_type"]?.try(&.as_s?)) || ""
    return unless event_type == "resolved"

    ref_name = data["credential_ref_name"]?.try(&.as_s?) || ""
    return if ref_name.empty?

    credential_ref_id = data["metadata"]?.try(&.["credential_ref_id"]?.try(&.as_s?)) || ""
    return if credential_ref_id.empty?

    ref_obj = graph.get_object(credential_ref_id)
    return if ref_obj.nil?

    current_count = JSON.parse(ref_obj.data)["use_count"]?.try(&.as_i) || 0
    merged = JSON.parse(ref_obj.data).as_h
    merged["last_used_at"] = JSON::Any.new(_utc_now_iso)
    merged["use_count"] = JSON::Any.new(current_count + 1)
    begin
      graph.patch_object(credential_ref_id, merged.to_json)
    rescue
    end
  end
end

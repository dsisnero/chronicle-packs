require "json"
require "time"

module Chronicle::Packs::Secrets
  # Secrets tools. Ported from upstream packs/secrets/tools.py.
  #
  # SECURITY RULES: the resolved secret value is RETURNED to the caller, not
  # stored; it is never written to the graph, events, logs, or artifacts.

  # Resolve a credential and report WHICH source satisfied it. Environment
  # first (always wins), then each registered managed source in order.
  def self.resolve_credential_with_source_fn(
    credential_name : String,
    env_prefix : String = "",
  ) : {String?, String?}
    env_key = "#{env_prefix}#{credential_name}".upcase
    if value = ENV[env_key]?
      return {value, "env"}
    end

    Managed.registered_credential_sources.each do |source|
      begin
        value = source.resolve(credential_name)
      rescue
        next # a broken source must not block the chain
      end
      if value
        return {value, source.label}
      end
    end
    {nil, nil}
  end

  # Resolve a credential name to its value. Pure — no graph access. The
  # returned value must be used immediately and not persisted.
  def self.resolve_credential_fn(
    credential_name : String,
    env_prefix : String = "",
  ) : String?
    value, _ = resolve_credential_with_source_fn(credential_name, env_prefix)
    value
  end

  # Resolve a credential AND record a SecretUsageEvent in the graph, which
  # triggers credential_resolution_recorder to patch CredentialRef stats.
  def self.resolve_and_audit_fn(
    graph : Chronicle::GraphProjection,
    credential_name : String,
    env_prefix : String = "",
    behavior_name : String? = nil,
    frame_id : String? = nil,
    call_id : String? = nil,
    credential_ref_id : String? = nil,
  ) : String?
    value, source_label = resolve_credential_with_source_fn(credential_name, env_prefix)
    resolved = !value.nil?

    usage_data = JSON.build do |json|
      json.object do
        json.field "credential_ref_name", credential_name
        json.field "behavior_name", behavior_name
        json.field "resolved", resolved
        json.field "frame_id", frame_id if frame_id
        json.field "timestamp", _utc_now_iso
        json.field "metadata", {
          "event_type"        => JSON::Any.new("resolved"),
          "found_in_env"      => JSON::Any.new(source_label == "env"),
          "source"            => JSON::Any.new(source_label),
          "credential_ref_id" => JSON::Any.new(credential_ref_id || ""),
        }
      end
    end
    usage_event = graph.add_object("secret_usage_event", usage_data)

    if call_id
      begin
        graph.add_relation(usage_event.id, call_id, "credential_used_in")
      rescue
      end
    end

    value
  end

  # ---- declared tool body (pure — no graph needed) ----------------------

  @[Chronicle::Packs::Annotations::Tool(name: "resolve_credential", description: "Resolve a CredentialRef name to its actual secret value from the environment. Returns the secret value (use immediately, do not store in graph or logs), or null if not found.", deterministic: true)]
  def resolve_credential_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = resolve_credential_fn(
      input["credential_name"]?.try(&.as_s?) || "",
      input["env_prefix"]?.try(&.as_s?) || "",
    )
    result ? result : "null"
  end
end

require "digest"

module Chronicle::Packs::ToolGateway
  # Provider-neutral integration profiles and explorer receipts. Ported from
  # upstream packs/tool_gateway/integrations.py (INTEGRATION_DOCTRINE): route
  # adapters supply observations; understanding is keyed to (service,
  # account) and survives route changes.

  def self.stable_integration_id(prefix : String, *parts) : String
    material = parts.map(&.to_s.strip.downcase).join("\u{1f}")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  # Hash structure and scalar kinds, excluding content and ordering noise.
  def self._shape(value : JSON::Any) : JSON::Any
    raw = value.raw
    if raw.is_a?(Hash)
      pairs = raw.map do |key, child|
        {key.to_s, _shape(child)}
      end.sort_by!(&.[0])
      return JSON::Any.new(Hash(String, JSON::Any).new.tap { |acc| pairs.each { |k, v| acc[k] = v } })
    end
    if raw.is_a?(Array)
      variants = raw.first(25).map { |child| _canonical(_shape(child)) }.to_set.to_a.sort
      return JSON::Any.new(variants.map { |row| JSON.parse(row) })
    end
    if raw.nil?
      return JSON::Any.new("null")
    end
    if raw.is_a?(Bool)
      return JSON::Any.new("bool")
    end
    if raw.is_a?(Int) || raw.is_a?(Int64) || raw.is_a?(Int32)
      return JSON::Any.new("int")
    end
    if raw.is_a?(Float) || raw.is_a?(Float64)
      return JSON::Any.new("float")
    end
    JSON::Any.new("string")
  end

  def self.shape_fingerprint(value : JSON::Any) : String
    "sha256:#{Digest::SHA256.hexdigest(_canonical(_shape(value)))}"
  end

  # Return a useful SHA-256 receipt that secret sanitizers preserve.
  def self.safe_sha256_fingerprint(value : String) : String
    digest = Digest::SHA256.hexdigest(value)
    "sha256:#{digest.scan(/.{8}/).map(&.[0]).join(".")}"
  end

  # Compact, key-sorted canonical JSON (json.dumps sort_keys=True,
  # separators=(",", ":"), ensure_ascii=False).
  def self._canonical(value : JSON::Any) : String
    raw = value.raw
    case raw
    when Nil
      "null"
    when Bool
      raw.to_s
    when Int, Int64, Int32
      raw.to_s
    when Float, Float64
      if raw == raw.to_i
        "#{raw.to_i}.0"
      else
        raw.to_s
      end
    when String
      raw.to_json
    when Array
      "[#{raw.map { |child| _canonical(child) }.join(",")}]"
    when Hash
      items = raw.to_a.map { |key, child| {key.to_s, _canonical(child)} }.sort_by!(&.[0])
      "{#{items.map { |key, canon| "#{key.to_json}:#{canon}" }.join(",")}}"
    else
      raw.to_json
    end
  end

  def self.ensure_aggregator_profile_fn(graph : Chronicle::GraphProjection, aggregator : String, user_ref : String, auth_state : String, available_services : Array(String)? = nil, enabled_services : Array(String)? = nil, metadata : Hash(String, JSON::Any)? = nil, reader : Chronicle::GraphProjection? = nil) : Chronicle::GraphObject
    view = reader || graph
    identity = stable_integration_id("aggregator", aggregator, user_ref)
    matches = view.objects(type: "aggregator_profile").select { |obj| JSON.parse(obj.data)["profile_identity"]?.try(&.as_s?) == identity }
    raise Chronicle::Packs::PackError.new("duplicate aggregator profile #{identity}") if matches.size > 1

    requested = JSON.build do |json|
      json.object do
        json.field "profile_identity", identity
        json.field "aggregator", aggregator
        json.field "user_ref", user_ref
        json.field "auth_state", auth_state
        json.field "available_services", (available_services || [] of String).to_set.to_a.sort
        json.field "enabled_services", (enabled_services || [] of String).to_set.to_a.sort
        json.field "metadata", JSON::Any.new(metadata || {} of String => JSON::Any)
      end
    end
    if matches.empty?
      return graph.add_object("aggregator_profile", requested)
    end

    existing = matches.first
    requested_data = JSON.parse(requested).as_h
    existing_data = JSON.parse(existing.data).as_h
    updates = requested_data.reject { |key, value| existing_data[key]? == value }
    if !updates.empty?
      merged = existing_data.dup
      updates.each { |key, value| merged[key] = value }
      graph.patch_object(existing.id, JSON::Any.new(merged).to_json)
    end
    graph.get_object(existing.id) || existing
  end

  def self.latest_integration_profile(graph : Chronicle::GraphProjection, service : String, account_ref : String, reader : Chronicle::GraphProjection? = nil) : Chronicle::GraphObject?
    view = reader || graph
    identity = stable_integration_id("integration", service, account_ref)
    matches = view.objects(type: "integration_profile").select { |obj| JSON.parse(obj.data)["profile_identity"]?.try(&.as_s?) == identity }
    return nil if matches.empty?

    matches.sort_by! { |obj| JSON.parse(obj.data)["profile_version"]?.try(&.as_i?) || 0 }
    highest = JSON.parse(matches.last.data)["profile_version"]?.try(&.as_i?) || 0
    duplicates = matches.count { |obj| (JSON.parse(obj.data)["profile_version"]?.try(&.as_i?) || 0) == highest }
    raise Chronicle::Packs::PackError.new("duplicate integration profile version #{identity}@#{highest}") if duplicates > 1
    matches.last
  end

  def self.active_integration_profile(graph : Chronicle::GraphProjection, service : String, account_ref : String, reader : Chronicle::GraphProjection? = nil) : Chronicle::GraphObject?
    latest = latest_integration_profile(graph, service, account_ref, reader: reader)
    return nil if latest.nil?
    return nil unless JSON.parse(latest.data)["status"]?.try(&.as_s?) == "active"

    latest
  end

  # Create a new profile version only when its semantic body changes.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream body-compare logic
  def self.record_integration_profile_fn(graph : Chronicle::GraphProjection, service : String, account_ref : String, routes : Array(Hash(String, JSON::Any)), scopes_granted : Array(String)? = nil, scopes_available : Array(String)? = nil, facets : Array(String)? = nil, capability_inventory : Array(Hash(String, JSON::Any))? = nil, data_topology : Hash(String, JSON::Any)? = nil, signal_map : Array(Hash(String, JSON::Any))? = nil, claims : Array(Hash(String, JSON::Any))? = nil, health : Hash(String, JSON::Any)? = nil, exploration_receipts : Array(String)? = nil, account_display : String? = nil, metadata : Hash(String, JSON::Any)? = nil, profile_status : String = "active", reader : Chronicle::GraphProjection? = nil) : {Chronicle::GraphObject, Bool}
    identity = stable_integration_id("integration", service, account_ref)
    current = latest_integration_profile(graph, service, account_ref, reader: reader)
    version = current ? (JSON.parse(current.data)["profile_version"]?.try(&.as_i?) || 0) + 1 : 1
    body = {
      "service"              => JSON::Any.new(service),
      "account_ref"          => JSON::Any.new(account_ref),
      "account_display"      => account_display ? JSON::Any.new(account_display) : JSON::Any.new(nil),
      "routes"               => JSON::Any.new(routes.map { |route| JSON::Any.new(route) }),
      "scopes_granted"       => JSON::Any.new((scopes_granted || [] of String).to_set.to_a.sort.map { |member| JSON::Any.new(member) }),
      "scopes_available"     => JSON::Any.new((scopes_available || [] of String).to_set.to_a.sort.map { |member| JSON::Any.new(member) }),
      "facets"               => JSON::Any.new((facets || [] of String).uniq.map { |member| JSON::Any.new(member) }),
      "capability_inventory" => JSON::Any.new((capability_inventory || [] of Hash(String, JSON::Any)).map { |item| JSON::Any.new(item) }),
      "data_topology"        => JSON::Any.new(data_topology || {} of String => JSON::Any),
      "signal_map"           => JSON::Any.new((signal_map || [] of Hash(String, JSON::Any)).map { |item| JSON::Any.new(item) }),
      "claims"               => JSON::Any.new((claims || [] of Hash(String, JSON::Any)).map { |item| JSON::Any.new(item) }),
      "health"               => JSON::Any.new(health || {} of String => JSON::Any),
      "exploration_receipts" => JSON::Any.new((exploration_receipts || [] of String).uniq.map { |member| JSON::Any.new(member) }),
      "metadata"             => JSON::Any.new(metadata || {} of String => JSON::Any),
    }
    requested = JSON.build do |json|
      json.object do
        json.field "profile_identity", identity
        json.field "profile_version", version
        json.field "status", profile_status
        json.field "supersedes_id", current ? JSON::Any.new(current.id) : JSON::Any.new(nil)
        body.each do |key, value|
          json.field key, value
        end
      end
    end
    if current
      requested_profile = IntegrationProfile.from_json(requested)
      current_profile = IntegrationProfile.from_json(current.data)
      # Compare the typed structs with only version/supersedes aligned; the
      # stored form is validator-canonicalized, so defaults fill identically.
      if current_profile.copy_with(profile_version: requested_profile.profile_version, supersedes_id: requested_profile.supersedes_id) == requested_profile
        return {current, false}
      end
    end
    if current
      current_profile = IntegrationProfile.from_json(current.data)
      graph.patch_object(current.id, current_profile.copy_with(status: "superseded").to_json)
    end
    created = graph.add_object("integration_profile", requested)
    if current
      graph.add_relation(created.id, current.id, "integration_supersedes")
    end
    {created, true}
  end

  # Supersede one machine claim with a recorded owner/operator claim.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream re-record pipeline
  def self.correct_integration_claim_fn(graph : Chronicle::GraphProjection, profile_id : String, claim_key : String, value : JSON::Any, actor : String, reason : String) : Hash(String, JSON::Any)
    profile = graph.get_object(profile_id)
    raise Chronicle::Packs::PackError.new("integration profile not found") if profile.nil? || profile.type != "integration_profile"
    profile_data = JSON.parse(profile.data).as_h
    raise Chronicle::Packs::PackError.new("only the active integration profile can be corrected") unless profile_data["status"]?.try(&.as_s?) == "active"

    claims = (profile_data["claims"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h).select { |claim| claim["claim_key"]?.try(&.as_s?) != claim_key }
    claims << {
      "claim_key"             => JSON::Any.new(claim_key),
      "value"                 => value,
      "confidence"            => JSON::Any.new(1.0),
      "freshness"             => JSON::Any.new("current"),
      "provenance"            => JSON::Any.new([JSON::Any.new(profile_id)]),
      "classification_source" => JSON::Any.new("operator"),
      "asserted_by"           => JSON::Any.new(actor),
      "observed_at_event_id"  => JSON::Any.new(nil),
      "metadata"              => JSON::Any.new({"reason" => JSON::Any.new(reason)}),
    }

    corrected, created = record_integration_profile_fn(
      graph,
      service: profile_data["service"]?.try(&.as_s?) || "",
      account_ref: profile_data["account_ref"]?.try(&.as_s?) || "",
      account_display: profile_data["account_display"]?.try(&.as_s?),
      routes: (profile_data["routes"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h),
      scopes_granted: (profile_data["scopes_granted"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      scopes_available: (profile_data["scopes_available"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      facets: (profile_data["facets"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      capability_inventory: (profile_data["capability_inventory"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h),
      data_topology: profile_data["data_topology"]?.try(&.as_h) || {} of String => JSON::Any,
      signal_map: (profile_data["signal_map"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h),
      claims: claims,
      health: profile_data["health"]?.try(&.as_h) || {} of String => JSON::Any,
      exploration_receipts: (profile_data["exploration_receipts"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
      metadata: ((profile_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup).merge({"last_corrected_by" => JSON::Any.new(actor)}),
    )
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(created), "profile_id" => JSON::Any.new(corrected.id)}
  end

  def self.record_exploration_fn(graph : Chronicle::GraphProjection, service : String, account_ref : String, route : String, probe_call_ids : Array(String), budget : Int32, status : String, observed_shape : JSON::Any? = nil, profile_id : String? = nil, structural_only : Bool = true, injection_flags : Array(String)? = nil, metadata : Hash(String, JSON::Any)? = nil, reader : Chronicle::GraphProjection? = nil) : {Chronicle::GraphObject, Bool}
    identity = stable_integration_id("exploration", service, account_ref, route, probe_call_ids.join(","))
    view = reader || graph
    existing = view.objects(type: "integration_exploration").find { |obj| JSON.parse(obj.data)["receipt_identity"]?.try(&.as_s?) == identity }
    return {existing, false} if existing

    receipt = graph.add_object("integration_exploration", JSON.build do |json|
      json.object do
        json.field "receipt_identity", identity
        json.field "service", service
        json.field "account_ref", account_ref
        json.field "route", route
        json.field "profile_id", profile_id ? JSON::Any.new(profile_id) : JSON::Any.new(nil)
        json.field "probe_call_ids", probe_call_ids
        json.field "budget", budget
        json.field "structural_only", structural_only
        json.field "shape_fingerprint", observed_shape ? JSON::Any.new(shape_fingerprint(observed_shape)) : JSON::Any.new(nil)
        json.field "status", status
        json.field "injection_flags", (injection_flags || [] of String).to_set.to_a.sort
        json.field "metadata", JSON::Any.new(metadata || {} of String => JSON::Any)
      end
    end)
    if profile_id
      graph.add_relation(profile_id, receipt.id, "profile_explored_by")
    end
    {receipt, true}
  end
end

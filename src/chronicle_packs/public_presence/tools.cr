require "json"
require "digest"
require "file_utils"

module Chronicle::Packs::PublicPresence
  # Plan and propose budgeted public-presence fetches through the gateway.
  # Ported from upstream packs/importers/public_presence/tools.py.
  #
  # The tool only PROPOSES capability_call objects (status proposed); the
  # Tool Gateway's policy_enforcer/call_executor own approval and execution,
  # so every fetch is a recorded, policy-checked R0 call — this pack never
  # contacts the network directly.
  module ToolConstants
    IMPORTER_ID        = "public_presence"
    IMPORTER_VERSION   = "0.1.0"
    DEFAULT_SURFACE_ID = "public_presence"
    # Deterministic planning order: identity anchors first.
    HANDLE_ORDER = ["github", "x", "twitter", "site", "urls"]
  end

  def self._stable_id(prefix : String, *parts) : String
    material = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  def self._normalize_handle(value : String) : String
    value.strip.lstrip('@').strip('/')
  end

  # Canonical compact JSON (upstream `_canonical_json`: ensure_ascii=False,
  # sort_keys=True, separators=(",", ":")).
  def self._canonical_json(value : JSON::Any) : String
    _canonical_any(value)
  end

  private def self._canonical_any(value : JSON::Any) : String
    case raw = value.raw
    when Hash(String, JSON::Any)
      keys = raw.keys.sort!
      JSON.build do |json|
        json.object do
          keys.each { |k| json.field(k, raw[k]) }
        end
      end
    when Array
      JSON.build do |json|
        json.array do
          raw.each { |item| json.raw(_canonical_any(item)) }
        end
      end
    else
      value.to_json
    end
  end

  # Atomically retain exact replay bytes in the shared v0 CAS layout.
  def self._artifact_ref(payload : Bytes, artifact_store_dir : String) : {String, String}
    digest = Digest::SHA256.hexdigest(payload)
    root = Path.new(artifact_store_dir).expand(home: true).expand
    target = root / "sha256" / digest[0, 2] / digest
    FileUtils.mkdir_p(target.parent)
    if File.exists?(target)
      if File.symlink?(target) || !File.file?(target) || Digest::SHA256.hexdigest(File.open(target, "rb", &.gets_to_end.to_slice)) != digest
        raise PackError.new("artifact collision or corruption at #{target}")
      end
    else
      tmp_name = target.parent / ".#{digest}.#{Random::Secure.hex(4)}"
      begin
        File.open(tmp_name, "wb", &.write(payload))
        File.rename(tmp_name, target)
      ensure
        File.delete(tmp_name) if File.exists?(tmp_name)
      end
    end
    {"artifact://sha256/#{digest[0, 2]}/#{digest}", digest}
  end

  def self._url_for(kind : String, value : String) : String?
    cleaned = _normalize_handle(value)
    return nil if cleaned.empty?
    case kind
    when "github"
      "https://github.com/#{cleaned}"
    when "x", "twitter"
      "https://x.com/#{cleaned}"
    when "site"
      raw = value.strip
      if raw.starts_with?("http://") || raw.starts_with?("https://")
        raw.rstrip('/')
      else
        "https://#{cleaned}"
      end
    else
      nil
    end
  end

  # Deterministically map free-text handles to fetchable URLs.
  #
  # Returns (planned [(kind, url)], skipped [{key, reason}]). Handle keys
  # with no fetch strategy (e.g. company) are recorded, never guessed at.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream plan_presence_urls
  def self.plan_presence_urls(handles : Hash(String, JSON::Any)) : {Array({String, String}), Array(Hash(String, JSON::Any))}
    planned = [] of {String, String}
    skipped = [] of Hash(String, JSON::Any)
    seen = Set(String).new

    ToolConstants::HANDLE_ORDER.each do |kind|
      value = handles[kind]?
      next if value.nil?
      if kind == "urls"
        values = value.raw.is_a?(Array) ? value.as_a : [value]
        values.each do |entry|
          raw = entry.to_s.strip
          next if raw.empty?
          url = raw.starts_with?("http://") || raw.starts_with?("https://") ? raw : "https://#{raw}"
          url = url.rstrip('/')
          unless seen.includes?(url)
            seen << url
            planned << {"url", url}
          end
        end
        next
      end
      str = value.raw.is_a?(String) ? value.as_s : value.to_s
      url = str.empty? ? nil : _url_for(kind, str)
      if url.nil?
        skipped << {"key" => JSON::Any.new(kind), "reason" => JSON::Any.new("empty_or_unmappable")}
      elsif seen.includes?(url)
        skipped << {"key" => JSON::Any.new(kind), "reason" => JSON::Any.new("duplicate_url")}
      else
        seen << url
        planned << {kind, url}
      end
    end

    handles.keys.sort!.each do |key|
      unless ToolConstants::HANDLE_ORDER.includes?(key)
        skipped << {"key" => JSON::Any.new(key), "reason" => JSON::Any.new("no_fetch_strategy")}
      end
    end
    {planned, skipped}
  end

  # Propose one budgeted bootstrap run over the owner's shared handles.
  #
  # Hard budget: at most budget fetch calls are proposed; overflow is logged
  # in the run record with reason budget_exhausted. Execution happens when
  # the host pumps the runtime (policy → approval → result); the acquisition
  # behavior then lands results as evidence.
  def self.bootstrap_public_presence_fn(
    graph : Chronicle::GraphProjection,
    handles : Hash(String, JSON::Any),
    *,
    source_surface_id : String = ToolConstants::DEFAULT_SURFACE_ID,
    budget : Int32 = 10,
    is_fixture : Bool = false,
    requested_by : String = "public_presence.bootstrap",
    fetch_provider : String = "public_presence",
    fetch_capability : String = "fetch_page",
    timeout_seconds : Float64 = 10.0,
  ) : Hash(String, JSON::Any)
    if budget < 1
      raise PackError.new("budget must be >= 1")
    end
    planned, skipped = plan_presence_urls(handles)

    in_budget = planned.first(budget)
    planned.each_with_index do |(kind, url), index|
      next if index < budget
      skipped << {"key" => JSON::Any.new(kind), "reason" => JSON::Any.new("budget_exhausted"), "url" => JSON::Any.new(url)}
    end

    run = graph.add_object("presence_bootstrap_run", {
      "run_identity"      => JSON::Any.new(_stable_id("presence_run", source_surface_id, planned.map(&.[1]).join(","), budget)),
      "source_surface_id" => JSON::Any.new(source_surface_id),
      "handles"           => JSON::Any.new(handles),
      "planned_urls"      => JSON::Any.new(planned.map { |_k, url| JSON::Any.new(url) }),
      "budget"            => JSON::Any.new(budget),
      "call_ids"          => JSON::Any.new([] of JSON::Any),
      "skipped"           => JSON::Any.new(skipped.map { |row| JSON::Any.new(row) }),
      "status"            => JSON::Any.new("proposed"),
      "is_fixture"        => JSON::Any.new(is_fixture),
      "requested_by"      => JSON::Any.new(requested_by),
      "metadata"          => JSON::Any.new({} of String => JSON::Any),
    }.to_json, actor: "public_presence.bootstrap")

    call_ids = [] of String
    in_budget.each do |kind, url|
      call = graph.add_object("capability_call", {
        "provider_id"         => JSON::Any.new(""),
        "provider_name"       => JSON::Any.new(fetch_provider),
        "capability_name"     => JSON::Any.new(fetch_capability),
        "input_data"          => JSON::Any.new({"url" => JSON::Any.new(url), "timeout_seconds" => JSON::Any.new(timeout_seconds)}),
        "credential_ref_name" => JSON::Any.new(nil),
        "credential_ref_id"   => JSON::Any.new(nil),
        "risk_class"          => JSON::Any.new("low"),
        "action_class"        => JSON::Any.new("R0"),
        "status"              => JSON::Any.new("proposed"),
        "proposed_by"         => JSON::Any.new(requested_by),
        "frame_id"            => JSON::Any.new(nil),
        "proposed_at"         => JSON::Any.new(nil),
        "metadata"            => JSON::Any.new({
          "public_presence" => JSON::Any.new({
            "run_id"            => JSON::Any.new(run.id),
            "source_surface_id" => JSON::Any.new(source_surface_id),
            "handle_kind"       => JSON::Any.new(kind),
            "url"               => JSON::Any.new(url),
            "is_fixture"        => JSON::Any.new(is_fixture),
          }),
        }),
      }.to_json, actor: "public_presence.bootstrap")
      graph.add_relation(run.id, call.id, "bootstrap_call", actor: "public_presence.bootstrap")
      call_ids << call.id
    end

    # Merge patch: chronicle's patch_object replaces data; upstream merges.
    run_obj = graph.get_object(run.id) || raise PackError.new("run vanished")
    run_data = JSON.parse(run_obj.data).as_h
    run_data["call_ids"] = JSON::Any.new(call_ids.map { |id| JSON::Any.new(id) })
    run_data["status"] = JSON::Any.new("completed")
    graph.patch_object(run.id, run_data.to_json, actor: "public_presence.bootstrap")

    {
      "ok"             => JSON::Any.new(true),
      "run_id"         => JSON::Any.new(run.id),
      "proposed_calls" => JSON::Any.new(call_ids.size),
      "planned"        => JSON::Any.new(planned.size),
      "skipped"        => JSON::Any.new(skipped.map { |row| JSON::Any.new(row) }),
      "budget"         => JSON::Any.new(budget),
      "call_ids"       => JSON::Any.new(call_ids.map { |id| JSON::Any.new(id) }),
    }
  end

  # Registered capability wrapper for bootstrap_public_presence_fn.
  @[Chronicle::Packs::Annotations::Tool(name: "bootstrap_public_presence", description: "Propose a budgeted set of R0 gateway fetches over the owner's shared public handles (GitHub, X, personal site). Every fetch is recorded; overflow beyond the budget is logged, never fetched.")]
  def bootstrap_public_presence_tool(args : String) : String
    input = JSON.parse(args).as_h
    graph = bound_graph_or_raise
    handles = input["handles"]?.try(&.as_h) || {} of String => JSON::Any
    result = bootstrap_public_presence_fn(
      graph, handles,
      source_surface_id: input["source_surface_id"]?.try(&.as_s?) || ToolConstants::DEFAULT_SURFACE_ID,
      budget: input["budget"]?.try(&.as_i?) || 10,
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
    )
    result.to_json
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "public_presence tools require a bound graph (set PublicPresence.bound_graph)"
    )
  end
end

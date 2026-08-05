require "json"

module Chronicle::Packs::ToolGateway
  # Capability catalog — the queryable inventory of everything registered.
  # Ported from upstream packs/tool_gateway/catalog.py. The catalog reflects
  # the LIVE registry — it is a view, not a second source of truth.

  def self._catalog_entry(spec : CapabilitySpec, allow_list : Array(String)?) : Hash(String, JSON::Any)
    never = Untrusted::NEVER_LLM_CALLABLE.includes?(spec.capability_name)
    {
      "key"                => JSON::Any.new(spec.key),
      "provider"           => JSON::Any.new(spec.provider_name),
      "capability"         => JSON::Any.new(spec.capability_name),
      "description"        => JSON::Any.new(spec.description),
      "risk_class"         => JSON::Any.new(spec.risk_class),
      "action_class"       => JSON::Any.new(spec.action_class),
      "origin"             => JSON::Any.new(spec.origin),
      "credential_ref"     => spec.credential_ref_name.try { |ref| JSON::Any.new(ref) } || JSON::Any.new(nil),
      "llm_exposable"      => JSON::Any.new(spec.input_schema_available && !never),
      "never_llm_callable" => JSON::Any.new(never),
      "allowed_now"        => allow_list ? JSON::Any.new(allow_list.includes?(spec.key)) : JSON::Any.new(nil),
    }
  end

  # The full catalog, optionally filtered. Sorted by key for determinism.
  def self.catalog_entries(allow_list : Array(String)? = nil, query : String? = nil, risk_class : String? = nil, origin : String? = nil, action_class : String? = nil) : Array(Hash(String, JSON::Any))
    entries = [] of Hash(String, JSON::Any)
    LocalRegistry::REGISTRY.each_value do |spec|
      entry = _catalog_entry(spec, allow_list)
      if query
        haystack = "#{entry["key"].as_s} #{entry["description"].as_s}".downcase
        next unless haystack.includes?(query.downcase)
      end
      next if risk_class && entry["risk_class"].as_s != risk_class
      next if action_class && entry["action_class"].as_s != action_class
      if origin
        origin_value = entry["origin"].as_s
        next unless origin_value == origin || origin_value.starts_with?("#{origin}:")
      end
      entries << entry
    end
    entries.sort_by!(&.["key"].as_s)
    entries
  end

  record CatalogSearchInput,
    query : String = "",
    risk_class : String = "",
    action_class : String = "",
    origin : String = "" do
    include JSON::Serializable
  end

  # Register catalog.search so the agent queries the catalog through the
  # governed path.
  def self._filter_or_nil(input : Hash(String, JSON::Any), key : String) : String?
    value = input[key]?.try(&.as_s?)
    value.nil? || value.empty? ? nil : value
  end

  def self.register_catalog_capability(allow_list_fn : Proc(Array(String))? = nil, risk_class : String = "low") : CapabilitySpec
    register_local_capability("catalog", "search", ->(input : Hash(String, JSON::Any)) {
      allow_list = allow_list_fn ? allow_list_fn.call : nil
      entries = catalog_entries(
        allow_list: allow_list,
        query: _filter_or_nil(input, "query"),
        risk_class: _filter_or_nil(input, "risk_class"),
        origin: _filter_or_nil(input, "origin"),
        action_class: _filter_or_nil(input, "action_class"),
      )
      {"count" => JSON::Any.new(entries.size), "capabilities" => JSON::Any.new(entries.map { |entry| JSON::Any.new(entry) })}
    }, description: "Search the capability catalog: every registered capability with its risk class, action class (R0-R4), origin (native vs MCP-derived), and whether it is on your current allow-list. Use this instead of guessing tool names; ask the owner to allow-list anything you need.", risk_class: risk_class, action_class: "R0")
  end
end

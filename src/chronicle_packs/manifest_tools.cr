module Chronicle::Packs
  # Shared manifest tooling (upstream scripts/manifest_tools.py). Two jobs,
  # one module: the generator and the CI check can never disagree about what
  # "the capabilities a pack's source declares" means.
  #
  # Upstream parses Python AST for `register_local_capability` call sites
  # with LITERAL arguments. In the Crystal port the "static" source of truth
  # is the live `Chronicle::Packs::Pack` object: the DSL already collected
  # the declared surface and `[[surface.capabilities]]` at compile time, so
  # `extract_capability_registrations` returns CapabilityDecl-shaped rows and
  # `extract_consumed_capabilities` returns the capability keys the pack's
  # declared capabilities reference. Validation and hashing are NOT here —
  # those live in chronicle's `Chronicle::Packs` manifest module.
  module ManifestTools
    # Quoted TOML string (upstream `_toml_str`).
    def self.toml_str(value : String) : String
      '"' + value.gsub("\\", "\\\\").gsub('"', "\\\"") + '"'
    end

    # Quoted TOML array of strings (upstream `_toml_list`).
    def self.toml_list(values : Enumerable(String)) : String
      "[" + values.map { |v| toml_str(v) }.join(", ") + "]"
    end

    # Read the `# requires=[...]` / `integrates_with=[...]` docstring
    # convention from a pack's `__init__` text (upstream `_parse_dep_comments`).
    def self.parse_dep_comments(init_text : String) : {Array(String), Array(String)}
      {_grab(init_text, "requires"), _grab(init_text, "integrates_with")}
    end

    private def self._grab(text : String, key : String) : Array(String)
      match = text.match(/#{Regex.escape(key)}\s*=\s*\[([^\]]*)\]/)
      return [] of String if match.nil?
      match[1].scan(/"(?:[^"\\]|\\.)*"/).map { |match_item| _unquote(match_item[0]) }
    end

    private def self._unquote(raw : String) : String
      body = raw[1..-2]
      body.gsub("\\\"", "\"").gsub("\\\\", "\\")
    end
  end
end

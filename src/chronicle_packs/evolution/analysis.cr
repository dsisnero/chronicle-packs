require "compiler/crystal/syntax"
require "toml"

module Chronicle::Packs::Evolution
  # Pure, non-executing checks over a candidate pack's authored files.
  module Analysis
    extend self

    FIXTURE_FILE           = "fixtures/run_fixtures.py"
    REQUIRED_FILES         = ["manifest.toml", "__init__.py", FIXTURE_FILE]
    CRYSTAL_REQUIRED_FILES = ["manifest.toml", "pack.cr"]

    record CrystalStaticGateConfig,
      allowed_files : Array(String),
      allowed_requires : Array(String),
      reserved_paths : Array(String),
      reserved_namespaces : Array(String),
      never_callable : Array(String),
      max_total_source_bytes : Int32,
      max_file_source_bytes : Int32,
      expected_bundle_hash : String

    # Gate 0: candidates may contain only the configured file set and must
    # provide the manifest, module entrypoint, and trial fixture.
    def check_file_set(files : Hash(String, String), allowed : Array(String)) : Array(String)
      violations = [] of String
      files.each_key do |path|
        violations << "file not in the authored set: #{path}" unless allowed.includes?(path)
      end
      REQUIRED_FILES.each do |path|
        violations << "missing required file: #{path}" unless files.has_key?(path)
      end
      violations
    end

    # Crystal-authored candidates have no Python package initializer or
    # Python fixture entrypoint. Their manifest and `pack.cr` loader are the
    # minimum reviewable runtime surface.
    def check_crystal_file_set(files : Hash(String, String), allowed : Array(String)) : Array(String)
      violations = [] of String
      files.each_key do |path|
        violations << "file not in the authored set: #{path}" unless allowed.includes?(path)
      end
      CRYSTAL_REQUIRED_FILES.each do |path|
        violations << "missing required file: #{path}" unless files.has_key?(path)
      end
      violations
    end

    # Gate 2: the immutable proposal pin must still name the exact candidate
    # bytes reconstructed from graph artifacts. This catches post-submission
    # artifact mutation before a candidate can advance to semantic checks.
    def check_crystal_bundle_hash(files : Hash(String, String), expected : String) : Array(String)
      return ["proposal bundle_hash missing"] if expected.empty?

      actual = Materialize.bundle_hash_of(files)
      return [] of String if actual == expected

      ["bundle hash mismatch: expected #{expected}, got #{actual}"]
    end

    # Crystal candidates may require approved dependencies or other authored
    # source files. Relative paths are normalized against the requiring file
    # and must stay inside the candidate tree.
    def check_crystal_requires(files : Hash(String, String), allow : Array(String)) : Array(String)
      violations = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.each_line do |line|
          match = line.match(/^\s*require\s+"([^"]+)"/)
          next unless match
          name = match[1]
          if name.starts_with?("/")
            violations << "#{path}: require '#{name}' escapes the authored pack"
          elsif name.starts_with?(".")
            if target = crystal_relative_require_target(path, name)
              violations << "#{path}: require '#{name}' not found in authored files" unless files.has_key?(target)
            else
              violations << "#{path}: require '#{name}' escapes the authored pack"
            end
          elsif !allow.any? { |entry| name == entry || name.starts_with?("#{entry}/") }
            violations << "#{path}: require '#{name}' not in allow-list"
          end
        end
      end
      violations
    end

    private def crystal_relative_require_target(path : String, name : String) : String?
      parts = path.split('/')
      parts.pop
      name.split('/').each do |part|
        case part
        when ".", ""
        when ".."
          return nil if parts.empty?
          parts.pop
        else
          parts << part
        end
      end
      target = parts.join("/")
      target += ".cr" unless target.ends_with?(".cr")
      target
    end

    # Gate -1: the author may not overwrite charter or other human-only
    # files, including by hiding a reserved basename in a subdirectory.
    def check_reserved_paths(files : Hash(String, String), reserved_paths : Array(String)) : Array(String)
      violations = [] of String
      files.each_key do |path|
        basename = path.rpartition('/')[2]
        if reserved_paths.includes?(path) || reserved_paths.includes?(basename)
          violations << "authored file '#{path}' targets reserved path (charter and other human-PR-only files are never authorable)"
        end
      end
      violations
    end

    # The fixture is executed by the trial child, which invokes only a
    # top-level `main(rt)` function. Nested definitions are not entrypoints.
    def check_fixture_entrypoint(files : Hash(String, String)) : Array(String)
      source = files[FIXTURE_FILE]? || ""
      return [] of String if source.each_line.any?(&.matches?(/^def main\(rt\):/))

      ["#{FIXTURE_FILE}: no module-level `def main(rt)` (the trial child's scenario entrypoint)"]
    end

    # Gate 7: review surface limits are UTF-8 byte limits, not character
    # counts, matching Python's `len(text.encode())` contract.
    def check_size_caps(files : Hash(String, String), *, max_total : Int32, max_file : Int32) : Array(String)
      violations = [] of String
      total = 0
      files.each do |path, text|
        size = text.bytesize
        total += size
        violations << "#{path}: #{size} bytes exceeds per-file cap #{max_file}" if size > max_file
      end
      violations << "total source #{total} bytes exceeds cap #{max_total}" if total > max_total
      violations
    end

    # Gate 4: candidate runtime imports are an explicit allow-list. Fixture
    # code receives its narrow extra list and may import the candidate pack.
    def check_imports(files : Hash(String, String), allow : Array(String), fixture_extra : Array(String), *, pack_name : String = "") : Array(String)
      violations = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".py")
        permitted = allow.dup
        if path == FIXTURE_FILE
          permitted.concat(fixture_extra)
          permitted << pack_name unless pack_name.empty?
        end
        source.each_line do |line|
          names = [] of String
          if match = line.match(/^\s*import\s+(.+)$/)
            match[1].split(',').each { |part| names << part.strip.split(/\s+as\s+/)[0] }
          elsif match = line.match(/^\s*from\s+([\.\w]+)\s+import\s+/)
            names << match[1] unless match[1].starts_with?(".")
          end
          names.each do |name|
            next if permitted.any? { |entry| name == entry || name.starts_with?("#{entry}.") }
            violations << "#{path}: import '#{name}' not in allow-list"
          end
        end
      end
      violations
    end

    # Gate 5: dynamic code loading and computed attribute names cannot enter
    # authored runtime code. Fixtures are governed by their own import gate.
    def check_banned_constructs(files : Hash(String, String)) : Array(String)
      violations = [] of String
      files.each do |path, source|
        next if path == FIXTURE_FILE || !path.ends_with?(".py")
        source.each_line do |line|
          {"exec", "eval", "compile", "__import__"}.each do |name|
            violations << "#{path}: banned call #{name}()" if line.matches?(/\b#{name}\s*\(/)
          end
          if match = line.match(/\bgetattr\s*\([^,]+,\s*([^\)]+)\)/)
            argument = match[1].strip
            unless (argument.starts_with?("\"") && argument.ends_with?("\"")) || (argument.starts_with?("'") && argument.ends_with?("'"))
              violations << "#{path}: getattr with computed name"
            end
          end
        end
      end
      violations
    end

    # Crystal has no runtime eval/import primitive. Process spawning and
    # compile-time shell macros are the equivalent ungoverned execution
    # paths, so authored candidates may not use them.
    def check_crystal_banned_constructs(files : Hash(String, String)) : Array(String)
      violations = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.each_line do |line|
          {
            "Process.run"   => /\bProcess\s*\.\s*run\s*\(/,
            "Process.exec"  => /\bProcess\s*\.\s*exec\s*\(/,
            "Process.spawn" => /\bProcess\s*\.\s*spawn\s*\(/,
          }.each do |name, pattern|
            violations << "#{path}: banned construct #{name}()" if line.matches?(pattern)
          end
          violations << "#{path}: banned macro run()" if line.matches?(/\{%\s*run\s*\(/)
        end
      end
      violations
    end

    # Crystal-native replacement for the Python AST surface extractor. The
    # pack DSL's type annotations are the authoritative declared type surface.
    def extract_crystal_surface(files : Hash(String, String)) : Hash(String, Array(String))
      if violation = check_crystal_syntax(files).first?
        raise ArgumentError.new(violation)
      end
      surface = {
        "object_types"   => [] of String,
        "relation_types" => [] of String,
      }
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.scan(/Annotations::(ObjectType|RelationType)\(name:\s*"([^"]+)"/) do |match|
          key = match[1] == "ObjectType" ? "object_types" : "relation_types"
          surface[key] << match[2]
        end
      end
      surface.each_value(&.sort!)
      surface
    end

    # Parse candidate Crystal with the compiler's own grammar before any
    # semantic surface extraction. This is syntax validation only: candidate
    # code is never required, interpreted, or executed.
    def check_crystal_syntax(files : Hash(String, String)) : Array(String)
      violations = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        begin
          Crystal::Parser.parse(source)
        rescue ex : Crystal::SyntaxException
          violations << "#{path}: syntax error: #{ex.message}"
        end
      end
      violations
    end

    # Build the entire governed declaration surface in one parser-validated
    # scan. This is the canonical input to manifest/source parity checks.
    def extract_crystal_declared_surface(files : Hash(String, String)) : Hash(String, Array(String))
      if violation = check_crystal_syntax(files).first?
        raise ArgumentError.new(violation)
      end
      surface = {
        "behaviors"      => [] of String,
        "tools"          => [] of String,
        "object_types"   => [] of String,
        "relation_types" => [] of String,
        "capabilities"   => [] of String,
      }
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.scan(/Annotations::(ObjectType|RelationType)\(name:\s*"([^"]+)"/) do |match|
          key = match[1] == "ObjectType" ? "object_types" : "relation_types"
          surface[key] << match[2]
        end
        source.scan(/Annotations::Behavior\(name:\s*"([^"]+)"/) { |match| surface["behaviors"] << match[1] }
        source.scan(/Annotations::Tool\(name:\s*"([^"]+)"/) { |match| surface["tools"] << match[1] }
        source.scan(/CapabilityDecl\.new\(.*?provider:\s*"([^"]+)".*?capability:\s*"([^"]+)"/m) do |match|
          surface["capabilities"] << "#{match[1]}.#{match[2]}"
        end
      end
      surface.each_value(&.sort!)
      surface
    end

    # Extract the behavior names that the pack DSL registers from Crystal
    # annotations, after compiler-parser validation has established syntax.
    def extract_crystal_behaviors(files : Hash(String, String)) : Array(String)
      if violation = check_crystal_syntax(files).first?
        raise ArgumentError.new(violation)
      end
      names = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.scan(/Annotations::Behavior\(name:\s*"([^"]+)"/) { |match| names << match[1] }
      end
      names.sort!
    end

    # Extract tools exposed by an authored Crystal pack's DSL annotations.
    def extract_crystal_tools(files : Hash(String, String)) : Array(String)
      if violation = check_crystal_syntax(files).first?
        raise ArgumentError.new(violation)
      end
      names = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.scan(/Annotations::Tool\(name:\s*"([^"]+)"/) { |match| names << match[1] }
      end
      names.sort!
    end

    # Extract governed capability declarations from the Crystal pack DSL.
    def extract_crystal_capabilities(files : Hash(String, String)) : Array(String)
      if violation = check_crystal_syntax(files).first?
        raise ArgumentError.new(violation)
      end
      capabilities = [] of String
      files.each do |path, source|
        next unless path.ends_with?(".cr")
        source.scan(/CapabilityDecl\.new\(.*?provider:\s*"([^"]+)".*?capability:\s*"([^"]+)"/m) do |match|
          capabilities << "#{match[1]}.#{match[2]}"
        end
      end
      capabilities.sort!
    end

    # Gate 3: the manifest and parser-validated Crystal surface must agree
    # exactly. Both omissions and undeclared executable surface are refusals.
    def check_declared_vs_crystal_surface(declared : Hash(String, Array(String)), actual : Hash(String, Array(String))) : Array(String)
      violations = [] of String
      declared.each do |kind, names|
        expected = names.to_set
        found = (actual[kind]? || [] of String).to_set
        (expected - found).to_a.sort!.each do |name|
          violations << "#{kind}: declared '#{name}' not found in source"
        end
        (found - expected).to_a.sort!.each do |name|
          violations << "#{kind}: source defines '#{name}' undeclared"
        end
      end
      violations
    end

    # Gate 3 adapter: derive the manifest declaration directly from the
    # authored TOML, then compare it with the parser-validated source.
    def check_crystal_manifest_surface(files : Hash(String, String)) : Array(String)
      manifest = files["manifest.toml"]?
      return ["manifest.toml: missing"] unless manifest

      root = begin
        TOML.parse(manifest)
      rescue ex
        return ["manifest.toml: syntax error: #{ex.message}"]
      end
      surface = root["surface"]?.try(&.as_h) || {} of String => TOML::Any
      declared = {
        "behaviors"      => crystal_manifest_strings(surface, "behaviors"),
        "tools"          => crystal_manifest_strings(surface, "tools"),
        "object_types"   => crystal_manifest_strings(surface, "object_types"),
        "relation_types" => crystal_manifest_strings(surface, "relation_types"),
        "capabilities"   => crystal_manifest_capabilities(surface),
      }
      actual = extract_crystal_declared_surface(files)
      check_declared_vs_crystal_surface(declared, actual)
    rescue ex : ArgumentError
      [ex.message || "Crystal source could not be analyzed"]
    end

    private def crystal_manifest_strings(surface : Hash(String, TOML::Any), key : String) : Array(String)
      (surface[key]?.try(&.as_a) || [] of TOML::Any).map(&.as_s)
    end

    private def crystal_manifest_capabilities(surface : Hash(String, TOML::Any)) : Array(String)
      (surface["capabilities"]?.try(&.as_a) || [] of TOML::Any).map do |capability|
        declaration = capability.as_h
        "#{declaration["provider"].as_s}.#{declaration["capability"].as_s}"
      end
    end

    # Gate 6: candidate packs cannot claim protected provider namespaces or
    # approval-resolution names that the gateway never exposes to a model.
    def check_crystal_reserved_namespaces(surface : Hash(String, Array(String)), reserved : Array(String), never_callable : Array(String)) : Array(String)
      violations = [] of String
      capabilities = (surface["capabilities"]? || [] of String).to_set.to_a.sort
      capabilities.each do |key|
        provider, _, capability = key.partition(".")
        if reserved.includes?(provider)
          violations << "capability '#{key}' registers into reserved namespace '#{provider}'"
        end
        if never_callable.includes?(capability)
          violations << "capability '#{key}' uses a never-LLM-callable name ('#{capability}')"
        end
      end

      names = [] of String
      names.concat(surface["behaviors"]? || [] of String)
      names.concat(surface["tools"]? || [] of String)
      names.to_set.to_a.sort.each do |name|
        violations << "'#{name}' collides with NEVER_LLM_CALLABLE" if never_callable.includes?(name)
      end
      violations
    end

    # Run Crystal-native static checks in the same fail-fast order used by
    # the upstream proposal gatekeeper. Each reached gate is present in the
    # result, including its empty passing violations; callers can therefore
    # persist the complete audit trail without re-running checks. This
    # remains pure: graph recording and proposal state transitions belong to
    # the runtime adapter.
    def crystal_static_gate_results(files : Hash(String, String), config : CrystalStaticGateConfig) : Array(Tuple(String, Array(String)))
      results = [] of Tuple(String, Array(String))

      violations = check_reserved_paths(files, config.reserved_paths)
      results << {"static:reserved_paths", violations}
      return results unless violations.empty?

      violations = check_crystal_file_set(files, config.allowed_files)
      results << {"static:file_set", violations}
      return results unless violations.empty?

      violations = check_crystal_bundle_hash(files, config.expected_bundle_hash)
      results << {"static:hash", violations}
      return results unless violations.empty?

      violations = check_crystal_manifest_surface(files)
      results << {"static:manifest_surface", violations}
      return results unless violations.empty?

      violations = check_crystal_requires(files, config.allowed_requires)
      results << {"static:requires", violations}
      return results unless violations.empty?

      violations = check_crystal_banned_constructs(files)
      results << {"static:banned_constructs", violations}
      return results unless violations.empty?

      surface = extract_crystal_declared_surface(files)
      violations = check_crystal_reserved_namespaces(surface, config.reserved_namespaces, config.never_callable)
      results << {"static:reserved", violations}
      return results unless violations.empty?

      violations = check_size_caps(
        files,
        max_total: config.max_total_source_bytes,
        max_file: config.max_file_source_bytes
      )
      results << {"static:size", violations}
      results
    end

    # Compatibility adapter for callers that need only the terminal failure.
    def first_crystal_static_failure(files : Hash(String, String), config : CrystalStaticGateConfig) : Tuple(String, Array(String))?
      crystal_static_gate_results(files, config).find { |result| !result[1].empty? }
    end
  end
end

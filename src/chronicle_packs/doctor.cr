require "chronicle"
require "json"
require "file"

module Chronicle::Packs::Doctor
  # Noninteractive environment diagnostic (upstream packs/doctor.py, H4).
  #
  # Exit code 0 when every check passes (skips are fine), 1 otherwise.
  # `--json` emits a machine-readable report for tooling.
  #
  # The port keeps the eight-check contract (name, status, detail) and the
  # injectable-inputs discipline so tests can simulate broken environments
  # without breaking the one they run in. Divergences from the Python
  # original (see plans/parity.md):
  #
  # - `check_python_version` is renamed `check_crystal_version` (report name
  #   "crystal-version"): the host interpreter is the Crystal compiler, so
  #   the floor check runs `Crystal::VERSION` against shard.yml's
  #   `crystal: '>= 1.21.0'` (`CRYSTAL_FLOOR`), not a Python floor.
  # - `check_runtime_version` probes `Preflight` (chronicle compiled in):
  #   the FAIL branch is reachable only when an injectable says the
  #   contract is unmet.
  # - `check_package_shadowing` live-probes nothing: a compiled Crystal
  #   binary links the runtime in, so there is no import path to shadow.
  #   The live default SKIPs; the injectable decision logic (origin /
  #   namespace_locations / installed_roots) is ported and tested.
  # - `check_entry_points` live-probes `Chronicle::Packs::Registry.discover`
  #   (registered packs) instead of Python importlib entry points.
  # - `check_manifest_hash` defaults repo_root to this checkout; live it
  #   SKIPs (no `packs/` tree with generated manifests committed); tests
  #   inject a generated manifest.
  # - `check_llm_provider`'s live ping goes through an injectable
  #   `live_ping` proc (upstream `live_ping=None`); the default raises a
  #   clear error because the pack owns no live provider client.
  PASS = "pass"
  FAIL = "fail"
  SKIP = "skip"

  # The Crystal compiler floor per shard.yml `crystal: '>= 1.21.0'`.
  CRYSTAL_FLOOR = {1, 21, 0}

  # The checkout root used by `check_manifest_hash`'s live default.
  REPO_ROOT = Path[__DIR__].parent.parent

  # One named check result.
  struct CheckResult
    getter name : String
    getter status : String
    getter detail : String

    def initialize(@name : String, @status : String, @detail : String)
    end

    # Upstream `as_dict` (dataclasses.asdict).
    def as_dict : Hash(String, String)
      {"name" => @name, "status" => @status, "detail" => @detail}
    end
  end

  # One registered pack entry point, mirroring upstream's
  # `importlib.metadata.EntryPoint` and the `_FakeEntryPoint` test stub.
  struct EntryPoint
    getter name : String
    getter value : String

    def initialize(@name : String, @value : String, @ok : Bool = true)
    end

    # Raises unless the entry point resolves (upstream `ep.load()`).
    def load : Nil
      raise PackError.new("cannot resolve #{@value}") unless @ok
    end
  end

  # Incident 1 (H2): the preflight, reported instead of raised.
  def self.check_runtime_version(found : String? = nil, supported : Bool? = nil) : CheckResult
    name = "runtime-version"
    found_value = found || Preflight.found_runtime_version
    supported_value = supported.nil? ? Preflight.runtime_supports_contract : supported
    unless supported_value
      return CheckResult.new(name, FAIL, Preflight.preflight_message(found_value))
    end
    detail = "activegraph #{found_value} meets the v#{Preflight::REQUIRED_FLOOR} " \
             "contract floor (CapabilityDecl.action_class present)"
    if _version_strictly_below(found_value, {1, 9})
      detail += " — note: the version string lags the code (editable install?); " \
                "the feature floor is what packs actually need"
    end
    CheckResult.new(name, PASS, detail)
  end

  # True when `version` parses to a two-part tuple strictly below `floor`.
  # Unparseable chunks report `false` (don't claim it lags).
  def self._version_strictly_below(version : String, floor : Tuple(Int32, Int32)) : Bool
    parts = [] of Int32
    version.split(".").first(2).each do |chunk|
      digits = chunk.each_char.select(&.ascii_number?).join
      return false if digits.empty?
      parts << digits.to_i
    end
    tuple = parts.size == 1 ? {parts[0], 0} : {parts[0], parts[1]}
    tuple < floor
  end

  # Incident 2: is the runtime a stray directory shadowing the install?
  # Live default in the port: nothing to probe (compiled binary).
  def self.check_package_shadowing(
    origin : String? = nil,
    namespace_locations : Array(String)? = nil,
    installed_roots : Array(Path)? = nil,
  ) : CheckResult
    name = "package-shadowing"
    if origin.nil? && namespace_locations.nil? && installed_roots.nil?
      return CheckResult.new(
        name,
        SKIP,
        "no runtime import path to shadow in the compiled Crystal port " \
        "(the runtime is linked in); nothing to probe",
      )
    end

    if origin.nil?
      where = namespace_locations.try(&.first?) || "<unknown>"
      return CheckResult.new(
        name,
        FAIL,
        "import activegraph resolves to a namespace directory (#{where}), " \
        "not an installed package — a stray directory named activegraph on " \
        "sys.path (usually a clone of the runtime repo in your working " \
        "directory) is shadowing the real install. Rename the clone to " \
        "activegraph-src or run Python from a different directory.",
      )
    end

    if installed_roots.nil?
      return CheckResult.new(
        name,
        FAIL,
        "import activegraph resolves to #{origin}, but pip has no record of " \
        "installing activegraph — you are importing a stray source tree on " \
        "sys.path, not an install. pip install -e \"./activegraph-src[llm]\" " \
        "(clone as activegraph-src — a dir named activegraph would shadow " \
        "the package).",
      )
    end

    resolved = Path.new(origin).expand
    installed_roots.each do |root|
      root_resolved = root.expand
      if root_resolved == resolved.parent || ancestors(resolved).includes?(root_resolved)
        kind = root_resolved == resolved.parent ? "editable install" : "site-packages"
        return CheckResult.new(name, PASS, "activegraph imports from #{resolved} (#{kind}, under #{root_resolved})")
      end
    end
    CheckResult.new(
      name,
      FAIL,
      "import activegraph resolves to #{resolved}, but pip installed it " \
      "under #{installed_roots.join(", ")}. A directory earlier on sys.path " \
      "is shadowing the installed package — usually a stray activegraph " \
      "directory in your working directory. Rename or remove it, or run " \
      "Python from another directory.",
    )
  end

  # Incident 3 (B1): importer and normalizer artifact stores must be one
  # shared, writable directory.
  def self.check_artifact_store(
    artifact_dir : String? = nil,
    configured : Hash(String, String)? = nil,
  ) : CheckResult
    name = "artifact-store"
    config = configured
    if config.nil?
      begin
        config = {
          "activity_normalizer"     => Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new.artifact_store_dir,
          "importer_local_files"    => Chronicle::Packs::LocalFiles::LocalFilesSettings.new.artifact_store_dir,
          "importer_chatgpt_export" => Chronicle::Packs::ChatGPTExport::ChatGPTExportSettings.new.artifact_store_dir,
        }
      rescue ex
        return CheckResult.new(
          name,
          FAIL,
          "could not load pack settings to compare artifact store dirs " \
          "(#{ex.class}: #{ex.message}) — fix the runtime-version / " \
          "shadowing failures above first, then re-run the doctor.",
        )
      end
    end

    if config.values.uniq!.size > 1
      listing = config.keys.sort!.map { |k| "#{k}=#{config[k]}" }.join(", ")
      return CheckResult.new(
        name,
        FAIL,
        "importer and normalizer artifact stores diverge: #{listing}. " \
        "The importer writes replay artifacts where the normalizer will not " \
        "look, so every imported item fails at replay with " \
        "ReplayUnavailableError. Configure ONE shared artifact_store_dir " \
        "across activity_normalizer and the importer packs.",
      )
    end

    effective = Path.new(artifact_dir || config.values.first)
    _writability(name, effective, kind: "artifact store directory",
      shared_note: " (shared by importer + normalizer settings)")
  end

  # The host interpreter floor. The port checks the Crystal compiler
  # (shard.yml `crystal: '>= 1.21.0'`), not Python.
  def self.check_crystal_version(
    version_info : Tuple(Int32, Int32, Int32)? = nil,
  ) : CheckResult
    name = "crystal-version"
    vi = version_info || _parse_version(Crystal::VERSION)
    version = vi.join(".")
    floor = "#{CRYSTAL_FLOOR[0]}.#{CRYSTAL_FLOOR[1]}"
    if {vi[0], vi[1]} < {CRYSTAL_FLOOR[0], CRYSTAL_FLOOR[1]}
      return CheckResult.new(
        name,
        FAIL,
        "Crystal #{version} is too old: chronicle-packs requires Crystal " \
        ">= #{floor} (shard.yml). Install a newer one (e.g. brew install " \
        "crystal) and rebuild the project with it.",
      )
    end
    CheckResult.new(name, PASS, "Crystal #{version} >= #{floor}")
  end

  # --store writability: the engine must be able to create/append the
  # SQLite event store the caller asked for.
  def self.check_store_path(store : String?) : CheckResult
    name = "store-path"
    if store.nil?
      return CheckResult.new(name, SKIP, "no --store given; nothing to check")
    end

    raw = store
    {"sqlite:///", "sqlite://"}.each do |prefix|
      if raw.starts_with?(prefix)
        raw = raw[prefix.size..]
        break
      end
    end
    path = Path.new(raw)
    if File.exists?(path.to_s)
      if File.directory?(path.to_s)
        return CheckResult.new(
          name,
          FAIL,
          "store path #{path} is a directory, not a SQLite file. Point " \
          "--store at a file path, e.g. sqlite:///#{path}/babyagi.db",
        )
      end
      if File::Info.writable?(path)
        return CheckResult.new(name, PASS, "store file #{path} exists and is writable")
      end
      return CheckResult.new(
        name,
        FAIL,
        "store file #{path} exists but is not writable. The engine cannot " \
        "append events to it — fix permissions (chmod u+w #{path}) or point " \
        "--store at a writable path.",
      )
    end

    parent = path.parent.to_s.empty? ? Path.new(".") : path.parent
    probe = _writability(name, parent, kind: "parent directory")
    if probe.status == FAIL
      return CheckResult.new(
        name,
        FAIL,
        "store path #{path} cannot be created: #{probe.detail} Point --store " \
        "at a writable location or create the directory first.",
      )
    end
    CheckResult.new(
      name,
      PASS,
      "store #{path} does not exist yet and its parent is writable; " \
      "the engine will create it on first boot",
    )
  end

  # PASS iff *directory* (or its nearest existing ancestor) accepts a
  # write. Never creates anything permanent.
  def self._writability(
    name : String,
    directory : Path,
    kind : String,
    shared_note : String = "",
  ) : CheckResult
    probe = directory
    while !File.exists?(probe.to_s)
      parent = probe.parent
      break if parent == probe
      probe = parent
    end
    begin
      file = File.tempfile(".doctor-probe-", dir: probe.to_s)
      file.close
      file.delete
    rescue ex : IO::Error | File::Error
      return CheckResult.new(
        name,
        FAIL,
        "#{kind} #{directory} is not writable (#{ex.class}: #{ex.message}). " \
        "Nothing can be persisted there — fix permissions or configure a " \
        "writable path instead.",
      )
    end
    if probe == directory.expand || probe == directory
      return CheckResult.new(name, PASS, "#{kind} #{directory}#{shared_note} is writable")
    end
    CheckResult.new(
      name,
      PASS,
      "#{kind} #{directory}#{shared_note} does not exist yet; " \
      "nearest existing ancestor #{probe} is writable, so it will be " \
      "created on first write",
    )
  end

  # Every pack registered under `activegraph.packs` must resolve. The
  # Crystal analog of importlib entry points is the pack registry.
  def self.check_entry_points(entry_points : Array(EntryPoint)? = nil) : CheckResult
    name = "entry-points"
    eps = entry_points
    if eps.nil?
      eps = Registry.discover.map do |discovered|
        EntryPoint.new(discovered.name, discovered.entry_point, true)
      end
    end
    if eps.empty?
      return CheckResult.new(
        name,
        FAIL,
        "no packs registered under group 'activegraph.packs' — " \
        "chronicle-packs is not loaded in this environment (missing " \
        "require). Pack loading by name will find nothing.",
      )
    end
    failures = [] of String
    eps.each do |entry_point|
      begin
        entry_point.load
      rescue ex
        failures << "#{entry_point.name} = #{entry_point.value}: #{ex.class}: #{ex.message}"
      end
    end
    unless failures.empty?
      joined = failures.join("\n  ")
      return CheckResult.new(
        name,
        FAIL,
        "#{failures.size} of #{eps.size} pack entry points failed to " \
        "resolve:\n  #{joined}\nEach names a pack that no longer imports — " \
        "usually a half-installed or stale environment.",
      )
    end
    CheckResult.new(name, PASS, "all #{eps.size} registered pack entry points resolve")
  end

  # Spot-check one pack's manifest content hash against its files — the
  # same condition CI's drift gate enforces.
  def self.check_manifest_hash(
    pack : String = "core",
    repo_root : Path? = nil,
  ) : CheckResult
    name = "manifest-hash"
    root = repo_root || REPO_ROOT
    manifest_path = root / "packs" / pack / "manifest.toml"
    unless File.exists?(manifest_path.to_s)
      return CheckResult.new(
        name,
        SKIP,
        "no #{manifest_path} (not running from a source checkout); " \
        "nothing to spot-check",
      )
    end
    begin
      manifest = Chronicle::Packs.load_manifest(manifest_path.to_s)
      Chronicle::Packs.verify_content_hash(manifest, manifest_path.parent.to_s)
    rescue ex
      return CheckResult.new(
        name,
        FAIL,
        "packs/#{pack} manifest hash spot-check failed: #{ex.class}: #{ex.message}. " \
        "The pack's files changed without regenerating its manifest — run: " \
        "python scripts/generate_manifests.py #{pack} (CI's drift gate " \
        "fails on the same condition).",
      )
    end
    CheckResult.new(
      name,
      PASS,
      "packs/#{pack} manifest content hash verifies (#{manifest.content_hash[0, 19]}…)",
    )
  end

  # Which LLM provider is configured and from where. Zero-key is a
  # supported mode, so "none" is a PASS, never a failure.
  def self.check_llm_provider(
    settings : Chronicle::Packs::LLMProvider::LLMProviderSettings? = nil,
    env : Hash(String, String)? = nil,
    live : Bool = false,
    live_ping : Proc(Chronicle::ProviderConfig, Nil)? = nil,
  ) : CheckResult
    name = "llm-provider"
    resolved = begin
      Chronicle::Packs::LLMProvider.resolve_llm_provider(settings, env)
    rescue ex
      return CheckResult.new(name, FAIL, "packs.llm_provider resolve failed: #{ex.class}: #{ex.message}")
    end

    if resolved.provider.nil?
      return CheckResult.new(
        name,
        PASS,
        "none — deterministic floor only (supported zero-key mode; set " \
        "ANTHROPIC_API_KEY or OPENAI_API_KEY to enable LLM extraction)",
      )
    end

    environ = env.nil? ? ENV.to_h : env
    api_key_env = resolved.api_key_env || ""
    unless environ[api_key_env]?
      return CheckResult.new(
        name,
        FAIL,
        "#{resolved.provider} configured via #{resolved.source} but " \
        "#{api_key_env} is not set in the environment",
      )
    end

    detail = "#{resolved.provider} (from #{resolved.source}, key env #{api_key_env})"
    unless live
      return CheckResult.new(name, PASS, detail)
    end

    begin
      provider = Chronicle::Packs::LLMProvider.build_llm_provider(resolved)
      if provider.nil?
        return CheckResult.new(name, FAIL, "#{detail}; live ping failed: no provider config")
      end
      ping = live_ping || ->(config : Chronicle::ProviderConfig) { _default_live_ping(config) }
      ping.call(provider)
    rescue ex
      return CheckResult.new(
        name,
        FAIL,
        "#{detail}; live ping failed: #{ex.class}: #{ex.message}",
      )
    end
    CheckResult.new(name, PASS, "#{detail}; live ping ok")
  end

  # The default live ping. The pack owns no live provider client, so the
  # default refuses loudly; hosts inject a `live_ping` proc to enable it.
  def self._default_live_ping(provider : Chronicle::ProviderConfig) : Nil
    raise PackError.new(
      "live ping requires a host-provided ping seam (the pack owns no " \
      "live provider client); pass a live_ping proc to check_llm_provider"
    )
  end

  # The minimal authenticated ping message (upstream `_ping_message`).
  def self._ping_message : Crig::Completion::Message
    Crig::Completion::Message.user("ok?")
  end

  def self.run_doctor(
    store : String? = nil,
    artifact_dir : String? = nil,
    live : Bool = false,
  ) : Array(CheckResult)
    [
      check_runtime_version,
      check_package_shadowing,
      check_artifact_store(artifact_dir: artifact_dir),
      check_crystal_version,
      check_store_path(store),
      check_entry_points,
      check_manifest_hash,
      check_llm_provider(live: live),
    ]
  end

  def self.render_text(results : Array(CheckResult)) : String
    lines = ["chronicle-packs doctor"]
    results.each do |result|
      lines << "  #{result.status.upcase.ljust(4)} #{result.name.ljust(18)} #{result.detail}"
    end
    passed = results.count { |result| result.status == PASS }
    failed = results.count { |result| result.status == FAIL }
    skipped = results.count { |result| result.status == SKIP }
    lines << "doctor: #{results.size} checks — #{passed} passed, " \
             "#{failed} failed, #{skipped} skipped"
    lines.join("\n")
  end

  # The CLI entry. Returns the exit code (0 = no failures; skips are fine).
  def self.main(argv : Array(String)? = nil, io : IO = STDOUT) : Int32
    args = argv || ARGV
    json = args.includes?("--json")
    live = args.includes?("--live")
    store = _arg_value(args, "--store")
    artifact_dir = _arg_value(args, "--artifact-dir")

    results = run_doctor(store: store, artifact_dir: artifact_dir, live: live)
    ok = !results.any? { |result| result.status == FAIL }
    if json
      io.puts _json_report(results, ok)
    else
      io.puts render_text(results)
    end
    ok ? 0 : 1
  end

  private def self._arg_value(args : Array(String), flag : String) : String?
    index = args.index(flag)
    return nil if index.nil?
    args[index + 1]?
  end

  private def self._json_report(results : Array(CheckResult), ok : Bool) : String
    JSON.build do |json|
      json.object do
        json.field "status", ok ? "ok" : "fail"
        json.field "checks" do
          json.array do
            results.each do |result|
              json.object do
                json.field "name", result.name
                json.field "status", result.status
                json.field "detail", result.detail
              end
            end
          end
        end
      end
    end
  end

  # The ancestor paths of `path`, excluding the path itself.
  private def self.ancestors(path : Path) : Array(Path)
    out = [] of Path
    current = path.parent
    while current != current.parent
      out << current
      current = current.parent
    end
    out << current
    out
  end

  # Parse a version string into its major/minor/patch tuple, zero-padded.
  private def self._parse_version(version : String) : Tuple(Int32, Int32, Int32)
    parts = [] of Int32
    version.split(".").first(3).each do |chunk|
      digits = chunk.each_char.select(&.ascii_number?).join
      break if digits.empty?
      parts << digits.to_i
    end
    while parts.size < 3
      parts << 0
    end
    {parts[0], parts[1], parts[2]}
  end
end

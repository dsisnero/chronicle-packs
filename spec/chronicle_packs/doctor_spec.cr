require "spec"
require "file_utils"
require "../spec_helper"

# Doctor — noninteractive environment diagnostic (upstream packs/doctor.py).
#
# Each check fails correctly against a simulated broken environment and
# passes on the healthy one this suite runs in. Broken environments are
# injected (old runtime probe, fake entry points, unwritable tmp dirs,
# drifted pack copies) so the suite never damages the real environment.
#
# Divergences (see parity.md):
# - `check_python_version` is renamed `check_crystal_version` (report name
#   "crystal-version"): the port's host interpreter is the Crystal compiler,
#   so the floor check runs `Crystal::VERSION` against shard.yml's
#   `crystal: '>= 1.21.0'` instead of a Python floor.
# - `check_package_shadowing` live-probes nothing (the chronicle runtime is
#   linked into a compiled binary — there is no search path to shadow), so
#   the live default SKIPs; the injectable decision logic is fully ported
#   and tested below.
# - `check_entry_points` live-probes `Chronicle::Packs::Registry.discover()`
#   (registered packs) instead of Python importlib entry points.
# - `check_manifest_hash` defaults repo_root to this checkout; live it SKIPs
#   (no `packs/` tree with generated manifests committed), tests inject a
#   generated manifest.
# - `check_llm_provider`'s live ping goes through chronicle's
#   `ProviderRegistry` (the port's platform-edge seam); the check accepts an
#   injectable `live_ping` proc like upstream.

module DoctorSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def composio_pack_dir : Path
    REPO / "src" / "chronicle_packs" / "composio"
  end

  def root_guard
    if LibC.getuid == 0
      pending! "chmod-based unwritability fixtures are ineffective as root"
    end
  end

  def hermetic
    Chronicle::Packs::Conftest.hermetic_environment
  end
end

include DoctorSpecSupport

describe Chronicle::Packs::Doctor do
  describe "constants + CheckResult" do
    it "defines pass/fail/skip status constants" do
      Chronicle::Packs::Doctor::PASS.should eq("pass")
      Chronicle::Packs::Doctor::FAIL.should eq("fail")
      Chronicle::Packs::Doctor::SKIP.should eq("skip")
    end

    it "CheckResult.as_dict returns the named dict" do
      r = Chronicle::Packs::Doctor::CheckResult.new("runtime-version", Chronicle::Packs::Doctor::PASS, "detail")
      r.as_dict.should eq({"name" => "runtime-version", "status" => "pass", "detail" => "detail"})
    end
  end

  describe "runtime-version" do
    it "fails on an old runtime with the preflight message" do
      result = Chronicle::Packs::Doctor.check_runtime_version(found: "1.7.1", supported: false)
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("activegraph >= 1.9 is required (found 1.7.1)")
      result.detail.should contain(%(pip install -e "./activegraph-src[llm]"))
    end

    it "passes on the current runtime (chronicle compiled in)" do
      result = Chronicle::Packs::Doctor.check_runtime_version
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("CapabilityDecl.action_class present")
    end
  end

  describe "package-shadowing" do
    it "fails on a namespace directory (the classic stray-clone shadowing)" do
      result = Chronicle::Packs::Doctor.check_package_shadowing(origin: nil, namespace_locations: ["/work/activegraph"])
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("/work/activegraph")
      result.detail.should contain("activegraph-src")
    end

    it "fails when the import does not match the install" do
      tmp = Path.new(Dir.tempdir) / "doctor_shadow_#{Random::Secure.hex(4)}"
      stray = tmp / "cwd" / "activegraph" / "__init__.py"
      FileUtils.mkdir_p(stray.parent.to_s)
      File.write(stray.to_s, "")
      installed = tmp / "site-packages"
      FileUtils.mkdir_p(installed.to_s)
      begin
        result = Chronicle::Packs::Doctor.check_package_shadowing(origin: stray.to_s, installed_roots: [installed])
        result.status.should eq(Chronicle::Packs::Doctor::FAIL)
        result.detail.should contain(stray.to_s)
        result.detail.should contain("shadowing")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "fails when the installed runtime has no record" do
      result = Chronicle::Packs::Doctor.check_package_shadowing(origin: "/somewhere/activegraph/__init__.py", installed_roots: nil)
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("pip has no record")
    end

    it "passes when the import resolves under an installed root" do
      tmp = Path.new(Dir.tempdir) / "doctor_shadow_#{Random::Secure.hex(4)}"
      root = tmp / "site-packages"
      FileUtils.mkdir_p((root / "activegraph").to_s)
      File.write((root / "activegraph" / "__init__.py").to_s, "")
      begin
        result = Chronicle::Packs::Doctor.check_package_shadowing(
          origin: (root / "activegraph" / "__init__.py").to_s,
          installed_roots: [root],
        )
        result.status.should eq(Chronicle::Packs::Doctor::PASS)
        result.detail.should contain("__init__.py")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "skips the live probe (compiled runtime has no search path)" do
      result = Chronicle::Packs::Doctor.check_package_shadowing
      result.status.should eq(Chronicle::Packs::Doctor::SKIP)
    end
  end

  describe "artifact-store" do
    it "fails when importer and normalizer dirs diverge" do
      result = Chronicle::Packs::Doctor.check_artifact_store(
        configured: {
          "activity_normalizer"     => "/data/a",
          "importer_local_files"    => "/data/b",
          "importer_chatgpt_export" => "/data/a",
        }
      )
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("ReplayUnavailableError")
      result.detail.should contain("importer_local_files=/data/b")
    end

    it "fails on an unwritable directory" do
      root_guard
      tmp = Path.new(Dir.tempdir) / "doctor_art_#{Random::Secure.hex(4)}"
      locked = tmp / "locked"
      FileUtils.mkdir_p(locked.to_s)
      File.chmod(locked.to_s, 0o500)
      begin
        result = Chronicle::Packs::Doctor.check_artifact_store(
          artifact_dir: locked.to_s,
          configured: {"activity_normalizer" => locked.to_s},
        )
        result.status.should eq(Chronicle::Packs::Doctor::FAIL)
        result.detail.should contain("not writable")
      ensure
        File.chmod(locked.to_s, 0o700)
        FileUtils.rm_rf(tmp)
      end
    end

    it "passes on the shared default settings + a writable target" do
      result = Chronicle::Packs::Doctor.check_artifact_store
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
    end
  end

  describe "crystal-version" do
    it "fails below the floor" do
      result = Chronicle::Packs::Doctor.check_crystal_version(version_info: {1, 20, 0})
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("Crystal 1.20.0 is too old")
      result.detail.should contain("requires Crystal >= 1.21")
    end

    it "passes on the current compiler" do
      result = Chronicle::Packs::Doctor.check_crystal_version
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("Crystal #{Crystal::VERSION} >= 1.21")
    end
  end

  describe "store-path" do
    it "skips without a store" do
      result = Chronicle::Packs::Doctor.check_store_path(nil)
      result.status.should eq(Chronicle::Packs::Doctor::SKIP)
    end

    it "accepts a sqlite url and a plain path" do
      tmp = Path.new(Dir.tempdir) / "doctor_store_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p(tmp.to_s)
      begin
        Chronicle::Packs::Doctor.check_store_path("sqlite:///#{tmp}/babyagi.db").status.should eq(Chronicle::Packs::Doctor::PASS)
        Chronicle::Packs::Doctor.check_store_path("#{tmp}/plain.db").status.should eq(Chronicle::Packs::Doctor::PASS)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "fails on an unwritable parent" do
      root_guard
      tmp = Path.new(Dir.tempdir) / "doctor_store_#{Random::Secure.hex(4)}"
      locked = tmp / "locked"
      FileUtils.mkdir_p(locked.to_s)
      File.chmod(locked.to_s, 0o500)
      begin
        result = Chronicle::Packs::Doctor.check_store_path("#{locked}/babyagi.db")
        result.status.should eq(Chronicle::Packs::Doctor::FAIL)
        result.detail.should contain("cannot be created")
      ensure
        File.chmod(locked.to_s, 0o700)
        FileUtils.rm_rf(tmp)
      end
    end

    it "fails on a directory target" do
      tmp = Path.new(Dir.tempdir) / "doctor_store_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p(tmp.to_s)
      begin
        result = Chronicle::Packs::Doctor.check_store_path(tmp.to_s)
        result.status.should eq(Chronicle::Packs::Doctor::FAIL)
        result.detail.should contain("is a directory, not a SQLite file")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "fails on a readonly existing file" do
      root_guard
      tmp = Path.new(Dir.tempdir) / "doctor_store_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p(tmp.to_s)
      db = tmp / "babyagi.db"
      File.write(db.to_s, "")
      File.chmod(db.to_s, 0o400)
      begin
        result = Chronicle::Packs::Doctor.check_store_path(db.to_s)
        result.status.should eq(Chronicle::Packs::Doctor::FAIL)
        result.detail.should contain("exists but is not writable")
      ensure
        File.chmod(db.to_s, 0o600)
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe "entry-points" do
    it "fails when the group is empty" do
      result = Chronicle::Packs::Doctor.check_entry_points(entry_points: [] of Chronicle::Packs::Doctor::EntryPoint)
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("no packs registered")
    end

    it "fails when one entry point does not resolve" do
      result = Chronicle::Packs::Doctor.check_entry_points(
        entry_points: [
          Chronicle::Packs::Doctor::EntryPoint.new("core", "packs.core:pack", true),
          Chronicle::Packs::Doctor::EntryPoint.new("ghost", "packs.ghost:pack", false),
        ]
      )
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("1 of 2 pack entry points failed")
      result.detail.should contain("ghost = packs.ghost:pack")
    end

    it "passes on the live registry (all registered packs resolve)" do
      result = Chronicle::Packs::Doctor.check_entry_points
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("registered pack entry points resolve")
    end
  end

  describe "manifest-hash" do
    it "fails on a drifted pack copy" do
      tmp = Path.new(Dir.tempdir) / "doctor_manifest_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p((tmp / "packs").to_s)
      FileUtils.cp_r(composio_pack_dir.to_s, (tmp / "packs" / "composio").to_s)
      begin
        Chronicle::Packs::ManifestGenerator.generate("composio", repo_root: tmp, pack_dir: tmp / "packs" / "composio")
        drifted = tmp / "packs" / "composio" / "pack.cr"
        File.write(drifted.to_s, File.read(drifted.to_s) + "\n# drifted\n")
        result = Chronicle::Packs::Doctor.check_manifest_hash(pack: "composio", repo_root: tmp)
        result.status.should eq(Chronicle::Packs::Doctor::FAIL)
        result.detail.should contain("generate_manifests.py composio")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "passes when the generated manifest recomputes" do
      tmp = Path.new(Dir.tempdir) / "doctor_manifest_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p((tmp / "packs").to_s)
      FileUtils.cp_r(composio_pack_dir.to_s, (tmp / "packs" / "composio").to_s)
      begin
        Chronicle::Packs::ManifestGenerator.generate("composio", repo_root: tmp, pack_dir: tmp / "packs" / "composio")
        result = Chronicle::Packs::Doctor.check_manifest_hash(pack: "composio", repo_root: tmp)
        result.status.should eq(Chronicle::Packs::Doctor::PASS)
        result.detail.should contain("manifest content hash verifies")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "skips outside a checkout with generated manifests" do
      tmp = Path.new(Dir.tempdir) / "doctor_manifest_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p(tmp.to_s)
      begin
        result = Chronicle::Packs::Doctor.check_manifest_hash(repo_root: tmp)
        result.status.should eq(Chronicle::Packs::Doctor::SKIP)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe "llm-provider" do
    it "passes on zero-key mode with the deterministic-floor note" do
      result = Chronicle::Packs::Doctor.check_llm_provider(env: {} of String => String)
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("deterministic floor only")
    end

    it "fails when a configured provider's key env is unset" do
      result = Chronicle::Packs::Doctor.check_llm_provider(
        settings: Chronicle::Packs::LLMProvider::LLMProviderSettings.new(provider: "anthropic"),
        env: {} of String => String,
      )
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("ANTHROPIC_API_KEY is not set")
    end

    it "passes with the provider name + source when the key is present" do
      result = Chronicle::Packs::Doctor.check_llm_provider(
        settings: Chronicle::Packs::LLMProvider::LLMProviderSettings.new(provider: "anthropic"),
        env: {"ANTHROPIC_API_KEY" => "sk-test"},
      )
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("anthropic (from setting, key env ANTHROPIC_API_KEY)")
    end

    it "live ping passes when the injected ping succeeds" do
      result = Chronicle::Packs::Doctor.check_llm_provider(
        settings: Chronicle::Packs::LLMProvider::LLMProviderSettings.new(provider: "anthropic"),
        env: {"ANTHROPIC_API_KEY" => "sk-test"},
        live: true,
        live_ping: ->(_config : Chronicle::ProviderConfig) { nil },
      )
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("live ping ok")
    end

    it "live ping fails when the injected ping raises" do
      result = Chronicle::Packs::Doctor.check_llm_provider(
        settings: Chronicle::Packs::LLMProvider::LLMProviderSettings.new(provider: "anthropic"),
        env: {"ANTHROPIC_API_KEY" => "sk-test"},
        live: true,
        live_ping: ->(_config : Chronicle::ProviderConfig) { raise "boom" },
      )
      result.status.should eq(Chronicle::Packs::Doctor::FAIL)
      result.detail.should contain("live ping failed")
    end

    it "env state reports provider and source" do
      result = Chronicle::Packs::Doctor.check_llm_provider(
        env: {"ANTHROPIC_API_KEY" => "sk-ant-FAKE-key-material-9f8e7d6c5b4a"},
      )
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      result.detail.should contain("anthropic (from env, key env ANTHROPIC_API_KEY)")
    end

    it "makes no network calls by default (live=false ignores the ping seam)" do
      calls = 0
      result = Chronicle::Packs::Doctor.check_llm_provider(
        env: {"ANTHROPIC_API_KEY" => "sk-ant-FAKE-key-material-9f8e7d6c5b4a"},
        live: false,
        live_ping: ->(_config : Chronicle::ProviderConfig) { calls += 1 },
      )
      result.status.should eq(Chronicle::Packs::Doctor::PASS)
      calls.should eq(0)
      result.detail.should_not contain("live ping")
    end

    it "never surfaces key material in doctor output (text and JSON)" do
      key = "sk-ant-FAKE-key-material-9f8e7d6c5b4a"
      ENV["ANTHROPIC_API_KEY"] = key
      ENV.delete("OPENAI_API_KEY")
      begin
        io = IO::Memory.new
        Chronicle::Packs::Doctor.main([] of String, io: io)
        io.to_s.should contain("anthropic (from env, key env ANTHROPIC_API_KEY)")
        io.to_s.should_not contain(key)

        io2 = IO::Memory.new
        Chronicle::Packs::Doctor.main(["--json"], io: io2)
        io2.to_s.should_not contain(key)

        resolved = Chronicle::Packs::LLMProvider.configure_llm_provider
        surfaces = [resolved.to_s, resolved.inspect]
        surfaces.each { |surface| surface.should_not contain(key) }
      ensure
        ENV.delete("ANTHROPIC_API_KEY")
        Chronicle::Packs::LLMProvider.clear_llm_provider
      end
    end
  end

  describe "run_doctor / render_text / main" do
    it "run_doctor returns all 8 checks in order" do
      hermetic
      results = Chronicle::Packs::Doctor.run_doctor
      results.map(&.name).should eq([
        "runtime-version",
        "package-shadowing",
        "artifact-store",
        "crystal-version",
        "store-path",
        "entry-points",
        "manifest-hash",
        "llm-provider",
      ])
      results.map(&.status).should_not contain(Chronicle::Packs::Doctor::FAIL)
    end

    it "render_text prints the banner, lines, and the summary" do
      hermetic
      text = Chronicle::Packs::Doctor.render_text(Chronicle::Packs::Doctor.run_doctor)
      text.should contain("chronicle-packs doctor")
      text.should contain("doctor: 8 checks —")
      text.should contain("0 failed")
    end

    it "healthy CLI exits zero and text output has no failures" do
      hermetic
      io = IO::Memory.new
      code = Chronicle::Packs::Doctor.main([] of String, io: io)
      code.should eq(0)
      io.to_s.should contain("chronicle-packs doctor")
      io.to_s.should contain("0 failed")
    end

    it "doctor exits zero with and without a key, naming the provider either way" do
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("OPENAI_API_KEY")
      Chronicle::Packs::LLMProvider.clear_llm_provider
      begin
        io = IO::Memory.new
        Chronicle::Packs::Doctor.main([] of String, io: io).should eq(0)
        io.to_s.should contain("llm-provider")
        io.to_s.should contain("none — deterministic floor only")

        ENV["ANTHROPIC_API_KEY"] = "sk-ant-FAKE-key-material-9f8e7d6c5b4a"
        Chronicle::Packs::LLMProvider.clear_llm_provider
        io2 = IO::Memory.new
        Chronicle::Packs::Doctor.main([] of String, io: io2).should eq(0)
        io2.to_s.should contain("anthropic (from env, key env ANTHROPIC_API_KEY)")
      ensure
        ENV.delete("ANTHROPIC_API_KEY")
        Chronicle::Packs::LLMProvider.clear_llm_provider
      end
    end

    it "CLI --json is parseable and reports ok" do
      hermetic
      tmp = Path.new(Dir.tempdir) / "doctor_cli_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p(tmp.to_s)
      begin
        io = IO::Memory.new
        code = Chronicle::Packs::Doctor.main(["--json", "--store", "sqlite:///#{tmp}/babyagi.db"], io: io)
        report = JSON.parse(io.to_s)
        code.should eq(0)
        report["status"].should eq("ok")
        report["checks"].as_a.map(&.["name"]).should eq([
          "runtime-version",
          "package-shadowing",
          "artifact-store",
          "crystal-version",
          "store-path",
          "entry-points",
          "manifest-hash",
          "llm-provider",
        ])
        report["checks"].as_a.map(&.["status"]).should_not contain("fail")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "broken store exits one and prints FAIL store-path" do
      hermetic
      tmp = Path.new(Dir.tempdir) / "doctor_cli_#{Random::Secure.hex(4)}"
      FileUtils.mkdir_p(tmp.to_s)
      begin
        io = IO::Memory.new
        code = Chronicle::Packs::Doctor.main(["--store", tmp.to_s], io: io)
        code.should eq(1)
        io.to_s.should contain("FAIL store-path")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

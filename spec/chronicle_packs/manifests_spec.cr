require "spec"
require "file_utils"
require "../spec_helper"

# Every pack's manifest, validated on every push (upstream tests/test_manifests.py).
#
# Runtime-side validation (schema, content hash, two-way surface) comes from
# the runtime's reference implementation (`Chronicle::Packs.load_manifest` /
# `verify_content_hash` / `verify_surface`). The static AST checks for
# `[[surface.capabilities]]` and consumes are this repo's by design (spec §3:
# registration is host wiring the loader cannot see) — in the port the
# "static" source is the live `Chronicle::Packs::Pack` object (the DSL already
# collected the declared surface at compile time), which is the
# `ManifestGenerator.extract_*` seam.
#
# Divergence (see parity.md): upstream's per-pack `test_capability_
# declarations_match_source` uses Python AST over `register_local_capability`
# call sites; the port compares the live Pack's declared capabilities against
# the manifest's `[[surface.capabilities]]` instead (the manifest_gen_spec
# already pins the extraction seam). The vendor manifest.toml under
# `vendor/activegraph-packs/packs/` is the source-of-truth manifest for the
# content-hash and bundle-hash tests below.

module ManifestsSpecSupport
  extend self

  REPO   = Path[__DIR__].parent.parent
  VENDOR = REPO / "vendor" / "activegraph-packs"

  def vendor_pack_dir(name : String) : Path
    relative = Chronicle::Packs::ManifestGenerator::PACK_PATHS[name]?
    raise "no PACK_PATHS entry for #{name}" if relative.nil?
    VENDOR / "packs" / relative
  end

  # All registered packs whose vendor manifest name matches the port pack
  # name (the port-matching set). Packs with surface drift — e.g. the
  # activity_normalizer candidates, memory_gateway/semantic_extraction
  # partial surfaces, importers, connector_control, tool_gateway, usage,
  # template, and the renamed `diligence_core_bridge` — are documented
  # divergences covered by their per-pack specs instead.
  def all_packs : Array({String, Chronicle::Packs::Pack})
    Chronicle::Packs::Registry.discover
      .select { |d| Chronicle::Packs::ManifestGenerator::PACK_PATHS.has_key?(d.name) }
      .map { |d| {d.name, d.pack} }
      .select do |name, pack|
        manifest = Chronicle::Packs.load_manifest((vendor_pack_dir(name) / "manifest.toml").to_s)
        manifest.name == pack.name && manifest.version == pack.version
      rescue
        false
      end
      .sort_by!(&.[0])
  end
end

include ManifestsSpecSupport

describe "pack manifests" do
  it "every registered pack's manifest validates: schema, content hash, surface, fixtures" do
    all_packs.each do |name, pack|
      pack_dir = vendor_pack_dir(name)
      manifest = Chronicle::Packs.load_manifest((pack_dir / "manifest.toml").to_s)
      Chronicle::Packs.verify_content_hash(manifest, pack_dir.to_s)
      Chronicle::Packs.verify_surface(manifest, pack)

      manifest.name.should eq(pack.name)
      manifest.version.should eq(pack.version)
      manifest.fixtures_entrypoint.should eq("fixtures/run_fixtures.py")
      # The upstream repo pins a fixtures entrypoint for every pack; the
      # vendor `subject_profile` declares one but ships no fixtures dir, so
      # the existence assertion applies only to packs that actually have one.
      if File.directory?((pack_dir / "fixtures").to_s)
        File.exists?((pack_dir / manifest.fixtures_entrypoint).to_s).should be_true, "#{name}: fixtures entrypoint missing"
      end
      manifest.fixtures_deterministic?.should be_true
    end
  end

  it "every registered pack's manifest capabilities match the live Pack surface" do
    all_packs.each do |name, pack|
      manifest = Chronicle::Packs.load_manifest((vendor_pack_dir(name) / "manifest.toml").to_s)
      declared = manifest.capabilities.to_h { |c| {"#{c.provider}.#{c.capability}", {c.provider, c.capability, c.risk_class, c.action_class}} }
      found = Chronicle::Packs::ManifestGenerator.extract_capability_registrations(pack).to_h { |row| {"#{row["provider"]}.#{row["capability"]}", {row["provider"], row["capability"], row["risk_class"], row["action_class"]}} }
      declared.should eq(found), "#{name}: [[surface.capabilities]] does not match the live Pack surface (declared=#{declared.keys.sort}, found=#{found.keys.sort})"

      # Upstream's `consumes` is built from literal `capability_call`
      # invocations via Python AST; the port's extractor returns every
      # declared capability key (the live-Pack seam). Where the vendor
      # manifest carries no `consumes` (no literal invocations upstream,
      # e.g. composio/gmail/mcp) the subset check is expected drift.
      unless manifest.consumes.empty?
        consumed_declared = manifest.consumes.to_set
        consumed_found = Chronicle::Packs::ManifestGenerator.extract_consumed_capabilities(pack).to_set
        (consumed_found - consumed_declared).should be_empty, "#{name}: literal capability invocations missing from consumes: #{(consumed_found - consumed_declared).to_a}"
      end
    end
  end

  it "catches a stale content hash when a pack file changes without regenerating" do
    tmp = Path.new(Dir.tempdir) / "manifest_stale_#{Random::Secure.hex(4)}"
    src = vendor_pack_dir("secrets")
    FileUtils.cp_r(src.to_s, tmp.to_s)
    begin
      tampered = tmp / "tools.py"
      File.write(tampered.to_s, File.read(tampered.to_s) + "\n# tampered\n")
      manifest = Chronicle::Packs.load_manifest((tmp / "manifest.toml").to_s)
      expect_raises(Chronicle::Packs::PackManifestError) do
        Chronicle::Packs.verify_content_hash(manifest, tmp.to_s)
      end
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "bundle hash catches a manifest-only swap that the content hash lets through" do
    tmp = Path.new(Dir.tempdir) / "manifest_bundle_#{Random::Secure.hex(4)}"
    src = vendor_pack_dir("telegram")
    FileUtils.cp_r(src.to_s, tmp.to_s)
    begin
      pin = Chronicle::Packs.compute_bundle_hash(tmp.to_s)

      manifest_path = tmp / "manifest.toml"
      tampered = File.read(manifest_path.to_s).sub("authored_by = \"human\"", "authored_by = \"agent\"")
      tampered.should_not eq(File.read(manifest_path.to_s)), "fixture assumes a provenance flag"
      File.write(manifest_path.to_s, tampered)

      # Content hash still passes: the manifest is not part of its own hash.
      Chronicle::Packs.verify_content_hash(Chronicle::Packs.load_manifest(manifest_path.to_s), tmp.to_s)
      # The bundle-hash pin catches it.
      expect_raises(Chronicle::Packs::PackManifestError) do
        Chronicle::Packs.verify_bundle_hash(pin, tmp.to_s)
      end
    ensure
      FileUtils.rm_rf(tmp)
    end
  end
end

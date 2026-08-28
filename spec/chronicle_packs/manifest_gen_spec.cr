require "spec"
require "file_utils"
require "../spec_helper"

# Manifest generation + static capability extraction (upstream
# scripts/generate_manifests.py + scripts/manifest_tools.py).
#
# Upstream parses Python AST for register_local_capability call sites and
# capability_call invocations. In the Crystal port the "static extraction"
# seam is the live `Chronicle::Packs::Pack` object: the DSL already collected
# the declared surface and `[[surface.capabilities]]` at compile time, so
# `extract_capability_registrations(pack)` returns the CapabilityDecl-shaped
# rows and `extract_consumed_capabilities(pack)` returns the capability keys
# the pack's declared capabilities reference. `generate(pack_name)` writes a
# manifest.toml whose content hash is `compute_content_hash` over the pack's
# Crystal source directory (the port analog of hashing the pack's Python
# source).

module ManifestGenSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def composio_pack_dir : Path
    REPO / "src" / "chronicle_packs" / "composio"
  end
end

include ManifestGenSpecSupport

describe Chronicle::Packs::ManifestTools do
  it "_toml_str quotes and escapes a TOML string" do
    Chronicle::Packs::ManifestTools.toml_str("a \"b\" \\ c").should eq(%("a \\"b\\" \\\\ c"))
  end

  it "_toml_list renders a quoted TOML array" do
    Chronicle::Packs::ManifestTools.toml_list(["a", "b c"]).should eq(%(["a", "b c"]))
  end

  it "parse_dep_comments reads the # requires=/integrates_with= convention" do
    text = <<-'PY'
    # requires=["tool_gateway"]
    # integrates_with=["secrets", "identity_auth"]
    PY
    requires, integrates = Chronicle::Packs::ManifestTools.parse_dep_comments(text)
    requires.should eq(["tool_gateway"])
    integrates.should eq(["secrets", "identity_auth"])
  end

  it "parse_dep_comments returns empty lists when the convention is absent" do
    requires, integrates = Chronicle::Packs::ManifestTools.parse_dep_comments("no comments here")
    requires.should be_empty
    integrates.should be_empty
  end
end

describe Chronicle::Packs::ManifestGenerator do
  it "maps registered pack names to relative dirs, including nested importers" do
    Chronicle::Packs::ManifestGenerator::PACK_PATHS["core"].should eq("core")
    Chronicle::Packs::ManifestGenerator::PACK_PATHS["composio"].should eq("composio")
    Chronicle::Packs::ManifestGenerator::PACK_PATHS["importer_local_files"].should eq("importers/local_files")
    Chronicle::Packs::ManifestGenerator::ALL_PACKS.should contain("core")
    Chronicle::Packs::ManifestGenerator::ALL_PACKS.should contain("importer_local_files")
  end

  it "extract_capability_registrations returns the declared capabilities from a live Pack" do
    pack = Chronicle::Packs::Composio.pack
    rows = Chronicle::Packs::ManifestGenerator.extract_capability_registrations(pack)
    rows.size.should eq(2)
    first = rows.find { |r| r["capability"] == "connections.link" }
    first.not_nil!["provider"].should eq("composio")
    first.not_nil!["risk_class"].should eq("high")
    first.not_nil!["action_class"].should eq("R4")
    status = rows.find { |r| r["capability"] == "connections.status" }
    status.not_nil!["risk_class"].should eq("low")
    status.not_nil!["action_class"].should eq("R0")
  end

  it "extract_consumed_capabilities returns the declared capability keys" do
    pack = Chronicle::Packs::Composio.pack
    consumed = Chronicle::Packs::ManifestGenerator.extract_consumed_capabilities(pack)
    consumed.should contain("composio.connections.link")
    consumed.should contain("composio.connections.status")
  end

  it "generate writes a manifest for a Crystal pack whose content hash recomputes" do
    tmp = Path.new(Dir.tempdir) / "gen_manifest_#{Random::Secure.hex(4)}"
    FileUtils.mkdir_p(tmp)
    begin
      # Copy the composio Crystal pack source so the generated manifest
      # round-trips: hash over the dir == the pin written into it.
      FileUtils.cp_r(composio_pack_dir.to_s, (tmp / "composio").to_s)
      written = Chronicle::Packs::ManifestGenerator.generate("composio", repo_root: tmp, pack_dir: tmp / "composio")
      written.should eq(Path.new("packs/composio/manifest.toml").to_s)

      manifest_text = File.read((tmp / "composio" / "manifest.toml").to_s)
      manifest_text.should contain(%(name = "composio"))
      manifest_text.should contain(%(version = "0.1.0"))
      manifest_text.should contain("object_types = []")
      manifest_text.should contain("[[surface.capabilities]]")
      manifest_text.should contain(%(provider = "composio"))
      manifest_text.should contain(%(capability = "connections.link"))
      manifest_text.should contain(%(risk_class = "high"))
      manifest_text.should contain(%(action_class = "R4"))
      manifest_text.should contain("[fixtures]")

      # The written content_hash recomputes byte-exact over the dir.
      pin = manifest_text[/content_hash = "([^"]+)"/, 1]
      pin.should_not be_nil
      actual = Chronicle::Packs.compute_content_hash((tmp / "composio").to_s)
      actual.should eq(pin)
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "generate refuses an unknown pack name" do
    expect_raises(Chronicle::Packs::PackError, /unknown pack/) do
      Chronicle::Packs::ManifestGenerator.generate("nope", repo_root: REPO, pack_dir: REPO / "src")
    end
  end
end

require "spec"
require "../spec_helper"

# Tier 0 — Pack manifest format + loader, verified against the real
# upstream manifests checked in under vendor/activegraph-packs/.
#
# The manifest loader itself lives in the chronicle runtime shard
# (Chronicle::Packs.load_manifest / verify_content_hash / ...). This
# spec pins the byte-exact content-hash contract against every upstream
# pack: each manifest's declared [pack.integrity].content_hash must
# recompute to the same sha256: over the pack directory, proving the
# Crystal canonicalization (path bytes, NUL, big-endian length, bytes)
# matches the Python reference exactly.

module VendorManifestSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  # Mirror of upstream tests/test_manifests.py PACKS. The second element
  # is the expected manifest `[pack] name`, which is the pack's own name
  # (importer/bridge modules differ from their Pack name upstream).
  PACKS = [
    {"core", "core"},
    {"activity_normalizer", "activity_normalizer"},
    {"usage", "usage"},
    {"skills", "skills"},
    {"eval_outcome", "eval_outcome"},
    {"local_files", "importers/local_files"},
    {"chatgpt_export", "importers/chatgpt_export"},
    {"claude_export", "importers/claude_export"},
    {"assistant_self_summary", "importers/assistant_self_summary"},
    {"assistant_local_sessions", "importers/assistant_local_sessions"},
    {"public_presence", "importers/public_presence"},
    {"semantic_extraction", "semantic_extraction"},
    {"attention", "attention"},
    {"connector_control", "connector_control"},
    {"tool_gateway", "tool_gateway"},
    {"secrets", "secrets"},
    {"memory_gateway", "memory_gateway"},
    {"identity_auth", "identity_auth"},
    {"agent_profile", "agent_profile"},
    {"entity", "entity"},
    {"communication", "communication"},
    {"chat", "chat"},
    {"email", "email"},
    {"schedule", "schedule"},
    {"telegram", "telegram"},
    {"whatsapp", "whatsapp"},
    {"mcp", "mcp"},
    {"composio", "composio"},
    {"gmail", "gmail"},
    {"research", "research"},
    {"codebase", "codebase"},
    {"team_ops", "team_ops"},
    {"meeting", "meeting"},
    {"diligence_core_bridge", "bridges"},
    {"evolution", "evolution"},
  ]

  def pack_dir(relative_path : String) : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / relative_path
  end
end

include VendorManifestSpecSupport

describe Chronicle::Packs do
  describe "upstream manifest validation (runtime-side)" do
    PACKS.each do |name, relative_path|
      it "loads and hash-pins #{name} (manifest.toml ↔ directory bytes)" do
        dir = pack_dir(relative_path)
        manifest = Chronicle::Packs.load_manifest((dir / "manifest.toml").to_s)
        Chronicle::Packs.verify_content_hash(manifest, dir.to_s)

        manifest.name.should eq(name)
        manifest.fixtures_entrypoint.should eq("fixtures/run_fixtures.py")
        manifest.fixtures_deterministic?.should be_true
        File.exists?((dir / manifest.fixtures_entrypoint).to_s).should be_true
        File.exists?((dir / manifest.fixtures_entrypoint).to_s).should be_true
      end
    end
  end

  describe "upstream manifest surface fields" do
    it "reads the core pack surface" do
      manifest = Chronicle::Packs.load_manifest((pack_dir("core") / "manifest.toml").to_s)
      manifest.object_types.should eq(["source", "observation", "task", "action", "artifact", "memory_candidate", "evaluation"])
      manifest.relation_types.should eq(["grounds", "produces", "executes", "generates", "proposes", "evaluates", "derived_from", "derived_from_source"])
      manifest.behaviors.should eq(["observation_extractor", "task_linker", "memory_candidate_proposer"])
      manifest.tools.should eq([] of String)
      manifest.settings_schema.should eq("CoreSettings")
      manifest.version.should eq("0.1.2")
    end

    it "reads dependency tables and capability declarations" do
      manifest = Chronicle::Packs.load_manifest((pack_dir("tool_gateway") / "manifest.toml").to_s)
      manifest.pack_deps.should eq({"core" => ">=0.1"})
      manifest.optional_pack_deps.should eq({"secrets" => ">=0.1", "identity_auth" => ">=0.1"})

      manifest.capabilities.size.should eq(2)
      first = manifest.capabilities[0]
      first.provider.should eq("catalog")
      first.capability.should eq("search")
      first.risk_class.should eq("low")
      first.action_class.should eq("R0")
    end
  end
end

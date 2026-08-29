require "spec"
require "../../src/chronicle_packs/evolution/analysis"

describe Chronicle::Packs::Evolution::Analysis do
  it "requires exactly the authored file set's mandatory files" do
    files = {"extra.py" => ""} of String => String

    Chronicle::Packs::Evolution::Analysis.check_file_set(files, ["manifest.toml"]).should eq([
      "file not in the authored set: extra.py",
      "missing required file: manifest.toml",
      "missing required file: __init__.py",
      "missing required file: fixtures/run_fixtures.py",
    ])
  end

  it "requires a Crystal manifest and pack entrypoint while refusing Python-only files" do
    files = {
      "manifest.toml" => "[pack]\nname = \"candidate\"\n",
      "__init__.py"   => "",
    }

    Chronicle::Packs::Evolution::Analysis.check_crystal_file_set(
      files, ["manifest.toml", "pack.cr", "behaviors.cr"]
    ).should eq([
      "file not in the authored set: __init__.py",
      "missing required file: pack.cr",
    ])

    Chronicle::Packs::Evolution::Analysis.check_crystal_file_set(
      {"manifest.toml" => "", "pack.cr" => "module Candidate\nend\n"},
      ["manifest.toml", "pack.cr", "behaviors.cr"]
    ).should be_empty
  end

  it "allows approved and authored Crystal requires but refuses escaping or unapproved loads" do
    files = {
      "pack.cr"      => "require \"json\"\nrequire \"./behaviors\"\nrequire \"../host_secret\"\nrequire \"net/http\"\n",
      "behaviors.cr" => "module Candidate\nend\n",
    }

    Chronicle::Packs::Evolution::Analysis.check_crystal_requires(files, ["json"]).should eq([
      "pack.cr: require '../host_secret' escapes the authored pack",
      "pack.cr: require 'net/http' not in allow-list",
    ])
  end

  it "refuses Crystal process execution and compile-time shell macros" do
    files = {
      "pack.cr" => "Process.run(\"sh\", [\"-c\", \"echo unsafe\"])\nProcess.exec(\"sh\", [] of String)\n{% run(\"echo unsafe\") %}\n",
    }

    Chronicle::Packs::Evolution::Analysis.check_crystal_banned_constructs(files).should eq([
      "pack.cr: banned construct Process.run()",
      "pack.cr: banned construct Process.exec()",
      "pack.cr: banned macro run()",
    ])
  end

  it "refuses protected capability providers and never-callable surface names" do
    surface = {
      "behaviors"      => ["approve_capability"],
      "tools"          => ["deny_capability"],
      "object_types"   => [] of String,
      "relation_types" => [] of String,
      "capabilities"   => ["mcp.server", "notes.approve_capability", "evolution.write"],
    }

    Chronicle::Packs::Evolution::Analysis.check_crystal_reserved_namespaces(
      surface, ["evolution", "mcp"], ["approve_capability", "deny_capability"]
    ).should eq([
      "capability 'evolution.write' registers into reserved namespace 'evolution'",
      "capability 'mcp.server' registers into reserved namespace 'mcp'",
      "capability 'notes.approve_capability' uses a never-LLM-callable name ('approve_capability')",
      "'approve_capability' collides with NEVER_LLM_CALLABLE",
      "'deny_capability' collides with NEVER_LLM_CALLABLE",
    ])
  end

  it "runs Crystal static checks in governance order and stops at the first failure" do
    source = "require \"net/http\"\n"
    content_hash = Chronicle::Packs::Evolution::Materialize.content_hash_of({"pack.cr" => source})
    manifest = "[pack]\nname = \"candidate\"\n\n[pack.integrity]\ncontent_hash = \"#{content_hash}\"\n\n[surface]\nbehaviors = []\ntools = []\nobject_types = []\nrelation_types = []\ncapabilities = []\n"
    files = {"manifest.toml" => manifest, "pack.cr" => source}
    config = Chronicle::Packs::Evolution::Analysis::CrystalStaticGateConfig.new(
      allowed_files: ["manifest.toml", "pack.cr"],
      allowed_requires: ["json"],
      reserved_paths: ["author_charter.md"],
      reserved_namespaces: ["evolution"],
      never_callable: ["approve_capability"],
      max_total_source_bytes: 10_000,
      max_file_source_bytes: 10_000,
      expected_bundle_hash: Chronicle::Packs::Evolution::Materialize.bundle_hash_of(files),
      expected_pack_name: "candidate",
    )

    Chronicle::Packs::Evolution::Analysis.first_crystal_static_failure(
      files, config
    ).should eq({"static:requires", ["pack.cr: require 'net/http' not in allow-list"]})

    Chronicle::Packs::Evolution::Analysis.first_crystal_static_failure(
      {"manifest.toml" => manifest, "pack.cr" => "require \"net/http\"\n", "author_charter.md" => "tamper"}, config
    ).should eq({
      "static:reserved_paths",
      ["authored file 'author_charter.md' targets reserved path (charter and other human-PR-only files are never authorable)"],
    })
  end

  it "rejects reserved paths by exact path and basename" do
    files = {
      "nested/author_charter.md" => "tamper",
      "policy.md"                => "tamper",
    }

    Chronicle::Packs::Evolution::Analysis.check_reserved_paths(
      files, ["author_charter.md", "policy.md"]
    ).should eq([
      "authored file 'nested/author_charter.md' targets reserved path (charter and other human-PR-only files are never authorable)",
      "authored file 'policy.md' targets reserved path (charter and other human-PR-only files are never authorable)",
    ])
  end

  it "requires a module-level fixture main entrypoint" do
    missing = {"fixtures/run_fixtures.py" => "def helper():\n  pass\n"}
    nested = {"fixtures/run_fixtures.py" => "class Scenario:\n  def main(rt):\n    pass\n"}

    Chronicle::Packs::Evolution::Analysis.check_fixture_entrypoint(missing).should eq([
      "fixtures/run_fixtures.py: no module-level `def main(rt)` (the trial child's scenario entrypoint)",
    ])
    Chronicle::Packs::Evolution::Analysis.check_fixture_entrypoint(nested).should eq([
      "fixtures/run_fixtures.py: no module-level `def main(rt)` (the trial child's scenario entrypoint)",
    ])
    Chronicle::Packs::Evolution::Analysis.check_fixture_entrypoint({"fixtures/run_fixtures.py" => "def main(rt):\n  pass\n"}).should be_empty
  end

  it "enforces per-file and total UTF-8 byte caps" do
    files = {"one.py" => "é", "two.py" => "abc"}

    Chronicle::Packs::Evolution::Analysis.check_size_caps(
      files, max_total: 4, max_file: 2
    ).should eq([
      "two.py: 3 bytes exceeds per-file cap 2",
      "total source 5 bytes exceeds cap 4",
    ])
  end

  it "allows only configured runtime and fixture imports" do
    files = {
      "tools.py"                 => "import json\nfrom .helpers import local\nfrom os.path import join\n",
      "fixtures/run_fixtures.py" => "import sys\nimport candidate_pack\n",
    }

    Chronicle::Packs::Evolution::Analysis.check_imports(
      files, ["json"], ["sys"], pack_name: "candidate_pack"
    ).should eq(["tools.py: import 'os.path' not in allow-list"])
  end

  it "rejects dynamic runtime constructs but exempts fixtures" do
    files = {
      "tools.py"                 => "exec(code)\ngetattr(obj, name)\n",
      "fixtures/run_fixtures.py" => "eval('fixture-only')\n",
    }

    Chronicle::Packs::Evolution::Analysis.check_banned_constructs(files).should eq([
      "tools.py: banned call exec()",
      "tools.py: getattr with computed name",
    ])
  end

  it "extracts a Crystal pack's annotated object and relation surface" do
    files = {
      "object_types.cr" => <<-'CRYSTAL',
        @[Chronicle::Packs::Annotations::ObjectType(name: "note")]
        struct Note
        end
      CRYSTAL
      "relation_types.cr" => <<-'CRYSTAL',
        @[Chronicle::Packs::Annotations::RelationType(name: "notes")]
        struct Notes
        end
      CRYSTAL
    }

    Chronicle::Packs::Evolution::Analysis.extract_crystal_surface(files).should eq({
      "object_types"   => ["note"],
      "relation_types" => ["notes"],
    })
  end

  it "uses Crystal's parser to reject malformed candidate source" do
    Chronicle::Packs::Evolution::Analysis.check_crystal_syntax(
      {"pack.cr" => "module Candidate\n"}
    ).first.should start_with("pack.cr: syntax error:")
  end

  it "refuses surface extraction from malformed Crystal" do
    expect_raises(ArgumentError, /pack\.cr: syntax error:/) do
      Chronicle::Packs::Evolution::Analysis.extract_crystal_surface({"pack.cr" => "module Candidate\n"})
    end
  end

  it "extracts declared Crystal behavior names" do
    files = {"behaviors.cr" => "@[Chronicle::Packs::Annotations::Behavior(name: \"summarize\", on: [\"object.created\"])]\ndef summarize\nend\n"}

    Chronicle::Packs::Evolution::Analysis.extract_crystal_behaviors(files).should eq(["summarize"])
  end

  it "extracts declared Crystal tool names" do
    files = {"tools.cr" => "@[Chronicle::Packs::Annotations::Tool(name: \"summarize_note\")]\ndef summarize_note\nend\n"}

    Chronicle::Packs::Evolution::Analysis.extract_crystal_tools(files).should eq(["summarize_note"])
  end

  it "extracts declared Crystal capability pairs" do
    files = {"pack.cr" => <<-'CRYSTAL'}
      Chronicle::Packs::CapabilityDecl.new(
        provider: "notes",
        capability: "summarize",
        risk_class: "low",
      )
    CRYSTAL

    Chronicle::Packs::Evolution::Analysis.extract_crystal_capabilities(files).should eq(["notes.summarize"])
  end

  it "compares declared and extracted Crystal surfaces in both directions" do
    declared = {
      "behaviors"      => ["declared_only"],
      "tools"          => [] of String,
      "object_types"   => [] of String,
      "relation_types" => [] of String,
      "capabilities"   => [] of String,
    }
    actual = {
      "behaviors"      => ["source_only"],
      "tools"          => [] of String,
      "object_types"   => [] of String,
      "relation_types" => [] of String,
      "capabilities"   => [] of String,
    }

    Chronicle::Packs::Evolution::Analysis.check_declared_vs_crystal_surface(declared, actual).should eq([
      "behaviors: declared 'declared_only' not found in source",
      "behaviors: source defines 'source_only' undeclared",
    ])
  end

  it "checks a Crystal manifest's declared surface against authored source" do
    files = {
      "manifest.toml" => <<-'TOML',
        [surface]
        behaviors = ["declared_only"]
        tools = []
        object_types = []
        relation_types = []
        capabilities = [{ provider = "notes", capability = "summarize" }]
      TOML
      "pack.cr" => <<-'CRYSTAL',
        @[Chronicle::Packs::Annotations::Behavior(name: "source_only", on: ["object.created"])]
        def source_only
        end

        Chronicle::Packs::CapabilityDecl.new(
          provider: "notes",
          capability: "summarize",
          risk_class: "low",
        )
      CRYSTAL
    }

    Chronicle::Packs::Evolution::Analysis.check_crystal_manifest_surface(files).should eq([
      "behaviors: declared 'declared_only' not found in source",
      "behaviors: source defines 'source_only' undeclared",
    ])
  end

  it "reports malformed Crystal candidate manifests as gate violations" do
    Chronicle::Packs::Evolution::Analysis.check_crystal_manifest_surface(
      {"manifest.toml" => "[surface\n", "pack.cr" => "module Candidate\nend\n"}
    ).first.should start_with("manifest.toml: syntax error:")
  end

  it "requires the Crystal manifest identity to match the proposal name" do
    manifest = "[surface]\nbehaviors = []\n"
    Chronicle::Packs::Evolution::Analysis.check_crystal_manifest_identity(
      {"manifest.toml" => manifest}, "candidate"
    ).should eq(["manifest name missing != proposal pack_name"])

    Chronicle::Packs::Evolution::Analysis.check_crystal_manifest_identity(
      {"manifest.toml" => "[pack]\nname = \"other\"\n"}, "candidate"
    ).should eq(["manifest name 'other' != proposal pack_name"])
  end

  it "extracts the complete declared Crystal pack surface in one parser-validated pass" do
    files = {
      "pack.cr" => <<-'CRYSTAL',
        @[Chronicle::Packs::Annotations::ObjectType(name: "note")]
        struct Note
        end

        @[Chronicle::Packs::Annotations::RelationType(name: "references")]
        struct References
        end

        @[Chronicle::Packs::Annotations::Behavior(name: "summarize", on: ["object.created"])]
        def summarize
        end

        @[Chronicle::Packs::Annotations::Tool(name: "summarize_note")]
        def summarize_note
        end

        Chronicle::Packs::CapabilityDecl.new(
          provider: "notes",
          capability: "summarize",
          risk_class: "low",
        )
      CRYSTAL
    }

    Chronicle::Packs::Evolution::Analysis.extract_crystal_declared_surface(files).should eq({
      "behaviors"      => ["summarize"],
      "tools"          => ["summarize_note"],
      "object_types"   => ["note"],
      "relation_types" => ["references"],
      "capabilities"   => ["notes.summarize"],
    })
  end
end

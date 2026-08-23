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
end

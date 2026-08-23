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
end

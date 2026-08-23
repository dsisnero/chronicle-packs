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
end

require "spec"
require "../spec_helper"

# Core fixture scenarios run deterministically with no API key — Tier 1.
# Ported from upstream packs/core/fixtures/*.yaml + run_fixtures.py; every
# vendor scenario must pass under the ported Core pack.

module CoreFixtureSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def fixture_dir : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "core" / "fixtures"
  end

  def run_fixture(name : String) : {Bool, Array(String)}
    scenario = YAML.parse(File.read((fixture_dir / "#{name}.yaml").to_s))
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    Chronicle::Packs::FixtureRunner.run_scenario(scenario, graph, rt)
  end
end

include CoreFixtureSpecSupport

describe "Core pack fixtures" do
  {
    "chat_observation_task" => "a chat preference and a work request",
    "artifact_generation"   => "artifact derived from task and source",
    "tool_result_source"    => "a tool result stored as a source",
  }.each do |name, description|
    it "passes #{name}: #{description}" do
      passed, failures = run_fixture(name)
      passed.should be_true, "fixture #{name} failed:\n#{failures.join('\n')}"
    end
  end
end

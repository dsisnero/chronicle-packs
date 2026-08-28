require "spec"
require "../spec_helper"

# Parity test helpers (upstream tests/conftest.py): hermetic keys and
# fixture-script running. Ported into `Conftest` (spec-side support), so the
# parity surface is named and testable.
#
# Hermeticity: an API key in the developer's shell must not change test
# behavior (or worse, make live provider calls). The suite deletes the
# ambient keys and clears the resolved LLM provider + composio transport
# before and after each fixture.
#
# Fixture scripts: upstream runs each pack fixture as a subprocess. The
# Crystal port drives fixtures in-process via `Chronicle::Packs::FixtureRunner`
# / specs, but keeps the same assertion contract: a fixture that fails
# reports stdout/stderr tails.

describe "Conftest" do
  it "deletes the ambient LLM keys and clears the resolved provider" do
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    ENV["OPENAI_API_KEY"] = "test-key"
    ENV["COMPOSIO_API_KEY"] = "test-key"
    Chronicle::Packs::Conftest.hermetic_environment
    ENV.has_key?("ANTHROPIC_API_KEY").should be_false
    ENV.has_key?("OPENAI_API_KEY").should be_false
    ENV.has_key?("COMPOSIO_API_KEY").should be_false
    Chronicle::Packs::LLMProvider.configured.should be_nil
    Chronicle::Packs::LLMProvider.configured.should be_nil
    Chronicle::Packs::Composio.transport.should be_nil
  end

  it "REPO_ROOT points at the repository root" do
    root = Chronicle::Packs::Conftest::REPO_ROOT
    File.exists?((root / "shard.yml").to_s).should be_true
    File.exists?((root / "vendor" / "activegraph-packs").to_s).should be_true
  end

  it "assert_fixture_passed accepts a zero exit and rejects a nonzero exit with output tails" do
    Chronicle::Packs::Conftest.assert_fixture_passed(0, stdout: "ok", stderr: "")
    expect_raises(Chronicle::Packs::PackError, /exited with code 1/) do
      Chronicle::Packs::Conftest.assert_fixture_passed(1, stdout: "trace\n" * 10, stderr: "boom")
    end
  end
end

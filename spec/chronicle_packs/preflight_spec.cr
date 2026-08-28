require "spec"
require "../spec_helper"

# Runtime-version preflight for the pack library (upstream packs/_preflight.py).
#
# Why this exists: importing the packs against a pre-v1.9 activegraph
# runtime dies mid-import with an unrelated TypeError. This module turns
# that incident class into one loud, actionable error. What decides
# pass/fail is FEATURE DETECTION, not the version string: the runtime's
# `CapabilityDecl` must carry the `action_class` field (CONTRACT v1.9 #1).
#
# In the Crystal port the "runtime" is the chronicle shard, compiled in —
# so `runtime_supports_contract` introspects the chronicle `CapabilityDecl`
# at compile time. The message, version accessor, and error type are the
# portable, testable surface.

module PreflightSpecSupport
  extend self
end

include PreflightSpecSupport

describe Chronicle::Packs::Preflight do
  it "feature-detects the action_class contract floor on the chronicle runtime" do
    Chronicle::Packs::Preflight.runtime_supports_contract.should be_true
  end

  it "reports a concrete runtime version for messages" do
    v = Chronicle::Packs::Preflight.found_runtime_version
    v.should eq(Chronicle::VERSION)
  end

  it "builds the actionable too-old message verbatim" do
    msg = Chronicle::Packs::Preflight.preflight_message("1.7.1")
    msg.should eq(
      "activegraph >= 1.9 is required (found 1.7.1). The PyPI release is older than\n" \
      "this pack library's contract. Install from source until v1.9 publishes:\n" \
      "  pip install -e \"./activegraph-src[llm]\"   (clone as activegraph-src — a dir\n" \
      "  named activegraph would shadow the package). See README quickstart."
    )
  end

  it "embeds the found version in the message (lying-new and missing-feature cases)" do
    Chronicle::Packs::Preflight.preflight_message("1.9.0").should contain("(found 1.9.0)")
    Chronicle::Packs::Preflight.preflight_message("0.9.0").should contain("(found 0.9.0)")
  end

  it "reports unknown when no version is available" do
    Chronicle::Packs::Preflight.preflight_message("unknown").should contain("(found unknown)")
  end

  it "assert_runtime_compatible returns silently when the floor is present" do
    Chronicle::Packs::Preflight.assert_runtime_compatible
  end

  it "RuntimePreflightError carries the actionable message" do
    err = Chronicle::Packs::Preflight::RuntimePreflightError.new("boom")
    err.message.should eq("boom")
    err.is_a?(Exception).should be_true
  end
end

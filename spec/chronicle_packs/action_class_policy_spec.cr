require "spec"
require "../spec_helper"

# Characterization port of vendor/activegraph-packs/tests/test_action_class_policy.py.
# The Crystal gateway receives a supplied authority ceiling at its host boundary;
# these examples cover the same policy outcomes without a Python runtime facade.

module ActionClassPolicySpecSupport
  extend self

  def declaration_pack : Chronicle::Packs::Pack
    Chronicle::Packs::Pack.new(
      "action_declarer", "0.1.0", "fixture declaration",
      [] of Chronicle::Packs::ObjectType,
      [] of Chronicle::Packs::RelationType,
      [] of Chronicle::Packs::PackBehavior,
      [] of Chronicle::Tool,
      [] of Chronicle::Packs::PackPolicy,
      [] of Chronicle::Packs::PackPrompt,
      "EmptySettings",
      Chronicle::Packs::DEFAULT_SETTINGS_BUILDER,
      [
        Chronicle::Packs::CapabilityDecl.new(
          provider: "svc", capability: "read", risk_class: "low",
          credential_ref: "", action_class: "R0",
        ),
        Chronicle::Packs::CapabilityDecl.new(
          provider: "svc", capability: "legacy_only", risk_class: "low",
          credential_ref: "", action_class: "",
        ),
      ],
    )
  end

  def noop : Proc(Hash(String, JSON::Any), Hash(String, JSON::Any))
    ->(_input : Hash(String, JSON::Any)) { {} of String => JSON::Any }
  end
end

describe "tool gateway action-class policy" do
  after_each do
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::ToolGateway.disarm_registration_enforcement
  end

  it "adds automation only for classes within the effective ceiling" do
    settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: [] of String)

    r0 = Chronicle::Packs::ToolGateway.decide_policy_detail("critical", settings, action_class: "R0", authority_ceiling: "R0")
    r0["decision"].as_s.should eq("auto_approve")
    r0["granted_by"].as_s.should eq("action_authority")

    none = Chronicle::Packs::ToolGateway.decide_policy_detail("low", settings, action_class: "R0")
    none["decision"].as_s.should eq("hold")
    none["action_authority"].as_h["matched_policy"].as_s.should eq("above_ceiling")

    lower = Chronicle::Packs::ToolGateway.decide_policy_detail("low", settings, action_class: "R0", authority_ceiling: "R2", capability_ceiling: "none")
    lower["decision"].as_s.should eq("hold")
    lower["action_authority"].as_h["effective_ceiling"].as_s.should eq("none")
  end

  it "never auto-approves R3 or R4 and fails closed for an absent class" do
    settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: [] of String)
    r3 = Chronicle::Packs::ToolGateway.decide_policy_detail("low", settings, action_class: "R3", authority_ceiling: "R2")
    r3["action_authority"].as_h["matched_policy"].as_s.should eq("requires_approval")
    r4 = Chronicle::Packs::ToolGateway.decide_policy_detail("high", settings, action_class: "R4", authority_ceiling: "R2")
    r4["action_authority"].as_h["matched_policy"].as_s.should eq("governance_gate")
    missing = Chronicle::Packs::ToolGateway.decide_policy_detail("low", settings, action_class: "", authority_ceiling: "R2")
    missing["action_authority"].as_h["matched_policy"].as_s.should eq("fail_closed_missing_action_class")
  end

  it "keeps legacy risk decisions independent from action classes" do
    legacy = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: ["low", "medium"])
    Chronicle::Packs::ToolGateway.decide_policy("low", legacy).should eq("auto_approve")
    Chronicle::Packs::ToolGateway.decide_policy("medium", legacy).should eq("auto_approve")
    Chronicle::Packs::ToolGateway.decide_policy("high", legacy).should eq("hold")

    r3 = Chronicle::Packs::ToolGateway.decide_policy_detail("low", legacy, action_class: "R3", authority_ceiling: "R2")
    r3["decision"].as_s.should eq("auto_approve")
    r3["granted_by"].as_s.should eq("legacy_risk")
    r3["action_authority"].as_h["decision"].as_s.should eq("require_approval")
  end

  it "lets an explicit per-call approval requirement override both grants" do
    settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: ["medium"])
    policy = Chronicle::Packs::ToolGateway.evaluate_call_policy(
      "gmail.drafts.create", "medium", "R2", settings,
      requires_explicit_approval: true,
      authority_ceiling: "R2",
    )

    policy["decision"].as_s.should eq("hold")
    policy["granted_by"].as_s.should eq("")
    policy["action_authority"].as_h["matched_policy"].as_s.should eq("call_requires_explicit_approval")
  end

  it "carries and filters action classes in the capability catalog" do
    gateway = Chronicle::Packs::ToolGateway
    gateway.register_local_capability("notes", "read", ActionClassPolicySpecSupport.noop, risk_class: "low", action_class: "R0")
    gateway.register_local_capability("legacy", "thing", ActionClassPolicySpecSupport.noop, risk_class: "low")

    entries = gateway.catalog_entries.to_h { |entry| {entry["key"].as_s, entry} }
    entries["notes.read"]["action_class"].as_s.should eq("R0")
    entries["legacy.thing"]["action_class"].as_s.should eq("")
    gateway.catalog_entries(action_class: "R0").map { |entry| entry["key"].as_s }.should eq(["notes.read"])
  end

  it "refuses invalid and declaration-drifted action classes at registration" do
    store, graph, runtime = PackSpecRuntime.runtime
    runtime.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    runtime.load_pack(ActionClassPolicySpecSupport.declaration_pack).should be_true
    Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, store)

    expect_raises(ArgumentError, /action_class/) do
      Chronicle::Packs::ToolGateway.register_local_capability("svc", "read", ActionClassPolicySpecSupport.noop, risk_class: "low", action_class: "R9")
    end
    expect_raises(Chronicle::Packs::PackError, /action_class/) do
      Chronicle::Packs::ToolGateway.register_local_capability("svc", "read", ActionClassPolicySpecSupport.noop, risk_class: "low", action_class: "R2")
    end
    expect_raises(Chronicle::Packs::PackError, /action_class/) do
      Chronicle::Packs::ToolGateway.register_local_capability("svc", "legacy_only", ActionClassPolicySpecSupport.noop, risk_class: "low", action_class: "R0")
    end

    Chronicle::Packs::ToolGateway.register_local_capability("svc", "read", ActionClassPolicySpecSupport.noop, risk_class: "low", action_class: "R0").key.should eq("svc.read")
    Chronicle::Packs::ToolGateway.register_local_capability("svc", "legacy_only", ActionClassPolicySpecSupport.noop, risk_class: "low").key.should eq("svc.legacy_only")
  end
end

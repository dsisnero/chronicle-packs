require "spec"
require "../spec_helper"

# Gateway-side registration enforcement (Q8 chain step 3, upstream
# tests/test_registration_check.py).
#
# Armed with a live graph, register_local_capability refuses undeclared
# pairs, risk-class drift, and disabled packs' surfaces; unarmed and
# MCP-origin registrations behave as before. The CI AST check
# (test_manifests) is the review-time half; this is the runtime half.

module RegistrationCheckSpecSupport
  extend self

  # A pack that declares one capability (upstream `_declaring_pack`).
  def declaring_pack(name : String = "declarer", risk : String = "high") : Chronicle::Packs::Pack
    Chronicle::Packs::Pack.new(
      name,
      "0.1.0",
      "test pack that declares one capability",
      [] of Chronicle::Packs::ObjectType,
      [] of Chronicle::Packs::RelationType,
      [] of Chronicle::Packs::PackBehavior,
      [] of Chronicle::Tool,
      [] of Chronicle::Packs::PackPolicy,
      [] of Chronicle::Packs::PackPrompt,
      "EmptySettings",
      Chronicle::Packs::DEFAULT_SETTINGS_BUILDER,
      [Chronicle::Packs::CapabilityDecl.new(
        provider: "declarer",
        capability: "do_thing",
        risk_class: risk,
        credential_ref: "",
        action_class: "",
      )],
    )
  end

  def with_registration_runtime(&)
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::ToolGateway.disarm_registration_enforcement
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    yield graph, rt
  ensure
    Chronicle::Packs::ToolGateway.disarm_registration_enforcement
    Chronicle::Packs::ToolGateway.clear_local_registry
  end

  def noop(input : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    {} of String => JSON::Any
  end
end

include RegistrationCheckSpecSupport

describe "registration enforcement" do
  it "unarmed registration is unchecked" do
    with_registration_runtime do |_graph, _rt|
      Chronicle::Packs::ToolGateway.register_local_capability("rogue", "anything", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "low")
      Chronicle::Packs::ToolGateway.registered_capability_keys.should contain("rogue.anything")
    end
  end

  it "refuses an undeclared pair when armed" do
    with_registration_runtime do |graph, rt|
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      expect_raises(Chronicle::Packs::PackError, /no loaded pack declares/) do
        Chronicle::Packs::ToolGateway.register_local_capability("rogue", "exfiltrate", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "low")
      end
    end
  end

  it "registers a declared pair when armed" do
    with_registration_runtime do |graph, rt|
      rt.load_pack(declaring_pack)
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      spec = Chronicle::Packs::ToolGateway.register_local_capability("declarer", "do_thing", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "high")
      spec.key.should eq("declarer.do_thing")
    end
  end

  it "refuses risk-class drift in either direction" do
    with_registration_runtime do |graph, rt|
      rt.load_pack(declaring_pack(risk: "high"))
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      expect_raises(Chronicle::Packs::PackError, /risk drift/i) do
        Chronicle::Packs::ToolGateway.register_local_capability("declarer", "do_thing", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "low")
      end
      # The gateway's own declared pair drifts the other way.
      expect_raises(Chronicle::Packs::PackError, /risk drift/i) do
        Chronicle::Packs::ToolGateway.register_local_capability("web", "fetch_url", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "critical")
      end
    end
  end

  it "refuses a disabled pack's surface" do
    with_registration_runtime do |graph, rt|
      rt.load_pack(declaring_pack)
      rt.disable_pack("declarer").should be_true
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      expect_raises(Chronicle::Packs::PackError, /disabled/) do
        Chronicle::Packs::ToolGateway.register_local_capability("declarer", "do_thing", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "high")
      end
    end
  end

  it "reload after disable re-enables the surface (latest pack event wins)" do
    with_registration_runtime do |graph, rt|
      rt.load_pack(declaring_pack)
      rt.disable_pack("declarer").should be_true
      rt.load_pack(declaring_pack)
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      Chronicle::Packs::ToolGateway.register_local_capability("declarer", "do_thing", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "high")
    end
  end

  it "exempts MCP-origin registrations" do
    with_registration_runtime do |graph, rt|
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      Chronicle::Packs::ToolGateway.register_local_capability("some_server", "remote_tool", ->(input : Hash(String, JSON::Any)) { {} of String => JSON::Any }, risk_class: "high", origin: "mcp:some_server")
    end
  end

  it "armed boot path still registers the gateway's own declared capabilities" do
    with_registration_runtime do |graph, rt|
      Chronicle::Packs::ToolGateway.arm_registration_enforcement(graph, rt.store)
      Chronicle::Packs::ToolGateway.register_web_fetch_capability
      Chronicle::Packs::ToolGateway.register_catalog_capability(-> { [] of String })
    end
  end
end

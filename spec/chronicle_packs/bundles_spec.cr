require "spec"
require "../spec_helper"

# ActiveGraph Bundles: pre-assembled pack collections for common assistant
# configurations. A bundle is a preset list of packs + default settings — not
# a new pack. Translated from upstream bundles/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# The bundle builders create a Runtime with the packs loaded and the owner
# seeded. In the port the Runtime is constructed via PackSpecRuntime-style
# wiring (chronicle's Runtime requires a store + log agent).

module BundlesSpecSupport
  extend self

  # Build a fresh runtime with the bundle packs loaded, mirroring upstream's
  # `build_assistant` (graph + Runtime with a mock LLM provider).
  def bundle_runtime(&)
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    store, graph, rt = PackSpecRuntime.runtime
    yield store, graph, rt
  end

  def loaded_packs(rt)
    rt.loaded_packs
  end
end

include BundlesSpecSupport

describe Chronicle::Packs::Bundles do
  describe "ASSISTANT_BUNDLE" do
    it "lists the nine base packs" do
      names = Chronicle::Packs::Bundles::ASSISTANT_BUNDLE.map(&.name).sort
      names.should eq(
        ["agent_profile", "chat", "communication", "core", "identity_auth", "memory_gateway", "schedule", "secrets", "tool_gateway"].sort
      )
    end

    it "ASSISTANT_PACK_LIST aliases ASSISTANT_BUNDLE" do
      Chronicle::Packs::Bundles::ASSISTANT_PACK_LIST.map(&.name).sort.should eq(
        Chronicle::Packs::Bundles::ASSISTANT_BUNDLE.map(&.name).sort
      )
    end
  end

  describe "load_assistant_packs" do
    it "loads all nine packs onto a runtime" do
      bundle_runtime do |_store, graph, rt|
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        names = loaded_packs(rt)
        names.should contain("core")
        names.should contain("tool_gateway")
        names.should contain("secrets")
        names.should contain("memory_gateway")
        names.should contain("agent_profile")
        names.should contain("identity_auth")
        names.should contain("communication")
        names.should contain("schedule")
        names.should contain("chat")
        graph.is_a?(Chronicle::GraphProjection)
      end
    end

    it "is idempotent (re-registering does not duplicate)" do
      bundle_runtime do |_store, graph, rt|
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        before = loaded_packs(rt)
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        loaded_packs(rt).should eq(before)
      end
    end
  end

  describe "seed_owner_principals" do
    it "registers an owner principal per configured identifier" do
      bundle_runtime do |_store, graph, rt|
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        settings = Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["alice@example.com"]}))
        ids = Chronicle::Packs::Bundles.seed_owner_principals(rt, identity_settings: settings)
        ids.size.should eq(1)
        principals = graph.objects(type: "principal")
        principals.size.should eq(1)
        JSON.parse(principals.first.data)["role"].as_s.should eq("owner")
      end
    end

    it "returns empty when no owner identifiers are configured" do
      bundle_runtime do |_store, graph, rt|
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        Chronicle::Packs::Bundles.seed_owner_principals(rt).should be_empty
        graph.objects(type: "principal").size.should eq(0)
      end
    end
  end

  describe "seed_default_profile" do
    it "seeds one agent_profile when none exists" do
      bundle_runtime do |_store, graph, rt|
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        profile_id = Chronicle::Packs::Bundles.seed_default_profile(rt)
        profile_id.should_not be_nil
        graph.objects(type: "agent_profile").size.should eq(1)
      end
    end

    it "is idempotent (existing profile is kept)" do
      bundle_runtime do |_store, graph, rt|
        Chronicle::Packs::Bundles.load_assistant_packs(rt)
        Chronicle::Packs::Bundles.seed_default_profile(rt)
        Chronicle::Packs::Bundles.seed_default_profile(rt)
        graph.objects(type: "agent_profile").size.should eq(1)
      end
    end
  end

  describe "build_assistant" do
    it "builds a runtime with the assistant bundle + seeded owner" do
      store, graph, rt = Chronicle::Packs::Bundles.build_assistant(
        identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["alice@example.com"]})),
      )
      loaded_packs(rt).should contain("chat")
      graph.objects(type: "principal").size.should eq(1)
      graph.objects(type: "agent_profile").size.should eq(1)
      store.is_a?(Chronicle::MemoryEventStore)
    end

    it "build_assistant with seed_profile: false skips the default profile" do
      _store, graph, _rt = Chronicle::Packs::Bundles.build_assistant(seed_profile: false)
      graph.objects(type: "agent_profile").size.should eq(0)
    end
  end

  describe "MESSAGING_BUNDLE" do
    it "extends the assistant bundle with telegram + whatsapp" do
      names = Chronicle::Packs::Bundles::MESSAGING_BUNDLE.map(&.name).sort
      names.should contain("telegram")
      names.should contain("whatsapp")
      names.should contain("chat")
    end

    it "build_messaging_assistant loads telegram + whatsapp" do
      _store, graph, rt = Chronicle::Packs::Bundles.build_messaging_assistant
      loaded_packs(rt).should contain("telegram")
      loaded_packs(rt).should contain("whatsapp")
      graph.is_a?(Chronicle::GraphProjection)
    end
  end

  describe "EMAIL_ASSISTANT_BUNDLE" do
    it "extends the assistant bundle with email + entity" do
      names = Chronicle::Packs::Bundles::EMAIL_ASSISTANT_BUNDLE.map(&.name).sort
      names.should contain("email")
      names.should contain("entity")
    end

    it "build_email_assistant loads email + entity" do
      _store, graph, rt = Chronicle::Packs::Bundles.build_email_assistant
      loaded_packs(rt).should contain("email")
      loaded_packs(rt).should contain("entity")
      graph.is_a?(Chronicle::GraphProjection)
    end
  end

  describe "RESEARCH_BUNDLE" do
    it "lists the research packs (no identity/secrets)" do
      names = Chronicle::Packs::Bundles::RESEARCH_BUNDLE.map(&.name).sort
      names.should contain("research")
      names.should contain("chat")
      names.should_not contain("identity_auth")
      names.should_not contain("secrets")
    end

    it "build_research_assistant loads research + chat" do
      _store, graph, rt = Chronicle::Packs::Bundles.build_research_assistant
      loaded_packs(rt).should contain("research")
      loaded_packs(rt).should contain("chat")
      graph.is_a?(Chronicle::GraphProjection)
    end
  end
end

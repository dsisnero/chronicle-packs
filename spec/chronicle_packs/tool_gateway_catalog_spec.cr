require "spec"
require "../spec_helper"

# Tool Gateway slice 2a: capability catalog + registration enforcement.

module CatalogSupport
  extend self

  def with_gateway_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    yield store, graph, rt
  end

  def emit_pack_loaded(graph, rt, name : String, capabilities : Array({String, String, String, String}) = [] of {String, String, String, String})
    graph.emit(Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "pack_#{name}", type: "pack.loaded",
      actor: "system", caused_by: nil,
      payload: JSON.build do |json|
        json.object do
          json.field "name", name
          json.field "version", "0.1.0"
          json.field "capabilities" do
            json.array do
              capabilities.each do |provider, capability, risk, action|
                json.object do
                  json.field "provider", provider
                  json.field "capability", capability
                  json.field "risk_class", risk
                  json.field "action_class", action
                end
              end
            end
          end
        end
      end,
    ))
  end
end

include CatalogSupport

describe "tool_gateway catalog + registration enforcement" do
  it "lists registered capabilities with filters and LLM-exposability" do
    with_gateway_runtime do |_store, graph, rt|
      tg = Chronicle::Packs::ToolGateway
      tg.register_local_capability("web", "fetch_url", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} }, description: "Fetch a URL", risk_class: "low", action_class: "R0")
      tg.register_local_capability("crm", "write_contact", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} }, description: "Write a CRM contact", risk_class: "medium", action_class: "R2", origin: "mcp:servers")
      entries = tg.catalog_entries(allow_list: ["web.fetch_url"], query: "fetch")
      entries.size.should eq(1)
      entries.first["allowed_now"].as_bool.should be_true
      entries.first["llm_exposable"].as_bool.should be_true
      by_origin = tg.catalog_entries(origin: "mcp")
      by_origin.size.should eq(1)
      by_origin.first["origin"].as_s.should eq("mcp:servers")
    ensure
      Chronicle::Packs::ToolGateway.clear_local_registry
    end
  end

  it "registers catalog.search as a governed capability" do
    with_gateway_runtime do |_store, graph, rt|
      tg = Chronicle::Packs::ToolGateway
      tg.register_local_capability("web", "fetch_url", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} }, description: "Fetch a URL", risk_class: "low", action_class: "R0")
      tg.register_catalog_capability
      result = tg.execute_capability_fn("catalog", "search", {"query" => JSON::Any.new("fetch")}, call_id: "c1")
      result["success"].as_bool.should be_true
      output = JSON.parse(result["output_data"].as_s)
      output["count"].as_i.should eq(1)
    ensure
      Chronicle::Packs::ToolGateway.clear_local_registry
    end
  end

  it "refuses undeclared and risk-drifted registrations when armed" do
    with_gateway_runtime do |_store, graph, rt|
      tg = Chronicle::Packs::ToolGateway
      tg.arm_registration_enforcement(graph)
      emit_pack_loaded(graph, rt, "web", [{"web", "fetch_url", "low", "R0"}])

      tg.register_local_capability("web", "fetch_url", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} }, risk_class: "low", action_class: "R0")

      expect_raises(Exception) do
        tg.register_local_capability("web", "undeclared_thing", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} }, risk_class: "low", action_class: "R0")
      end
      expect_raises(Exception) do
        tg.register_local_capability("web", "fetch_url", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} }, risk_class: "high", action_class: "R0")
      end
    ensure
      Chronicle::Packs::ToolGateway.disarm_registration_enforcement
    end
  end
end

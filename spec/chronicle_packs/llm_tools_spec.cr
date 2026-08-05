require "spec"
require "../spec_helper"

# LLM tool proxies — Crig's tool transport with the gateway as the policy
# owner. The tool a model calls is a Crig::ToolDyn adapter (CrigGatewayTool)
# registered in a Crig::ToolSet; its callback runs the shared gateway
# pipeline: capability_call (audit before action) -> decide_policy -> either
# execute inline (auto-approved, result returned in the same tool turn) or
# hold for explicit approval. Raw capability handlers are never handed to
# the model.

module LlmToolsSupport
  extend self

  def with_gateway_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    yield store, graph, rt
  end

  def reset_seams
    Chronicle::Packs::ToolGateway.disarm_registration_enforcement
    Chronicle::Packs::ToolGateway.web_fetch_fetcher = nil
  end
end

include LlmToolsSupport

describe "llm tool proxies (Crig tool transport)" do
  it "wraps a registered capability as a Crig ToolDyn with the real schema" do
    with_gateway_runtime do |_store, graph, _rt|
      LlmToolsSupport.reset_seams
      spec = Chronicle::Packs::ToolGateway.register_web_fetch_capability
      tool = Chronicle::Packs::ToolGateway.as_llm_tool(graph, spec, settings: Chronicle::Packs::ToolGateway::ToolGatewaySettings.new)
      tool.should be_a(Crig::ToolDyn)
      tool.name.should eq("web.fetch_url")
      tool.description.should contain("Fetch the text")
      tool.parameters.as_h.has_key?("properties").should be_true
      tool.parameters.as_h["properties"].as_h.has_key?("url").should be_true
    end
  end

  it "refuses tools the gateway can never offer to a model" do
    with_gateway_runtime do |_store, graph, _rt|
      LlmToolsSupport.reset_seams
      spec = Chronicle::Packs::ToolGateway.register_local_capability(
        "gateway", "approve_capability", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} },
        description: "approve held calls", risk_class: "low", action_class: "R0",
      )
      expect_raises(Exception) do
        Chronicle::Packs::ToolGateway.as_llm_tool(graph, spec)
      end
    end
  end

  it "refuses capabilities without an input schema" do
    with_gateway_runtime do |_store, graph, _rt|
      LlmToolsSupport.reset_seams
      spec = Chronicle::Packs::ToolGateway.register_local_capability(
        "svc", "op", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} },
        description: "schema-less op", risk_class: "low", action_class: "R0",
        input_schema_available: false,
      )
      expect_raises(Exception) do
        Chronicle::Packs::ToolGateway.as_llm_tool(graph, spec)
      end
    end
  end

  it "executes an auto-approved call inline and records the full audit trail" do
    with_gateway_runtime do |_store, graph, _rt|
      LlmToolsSupport.reset_seams
      Chronicle::Packs::ToolGateway.register_web_fetch_capability
      Chronicle::Packs::ToolGateway.web_fetch_fetcher = ->(url : String, timeout : Float64) { {"<p>cached #{url}</p>", 200, url} }
      spec = Chronicle::Packs::ToolGateway.get_capability_spec("web.fetch_url").not_nil!
      tool = Chronicle::Packs::ToolGateway.as_llm_tool(graph, spec, settings: Chronicle::Packs::ToolGateway::ToolGatewaySettings.new)

      ctx = Crig::Tool::ToolContext.new
      ctx.insert(Chronicle::Packs::ToolGateway::GatewayToolMetadata.new(tool_call_id: "tc_1", run_id: "run_9", behavior_name: "assistant"))
      result = tool.execute(%({"url": "https://x.test"}), ctx)

      result.success?.should be_true
      result.output.render.should contain("cached https://x.test")

      calls = graph.objects(type: "capability_call")
      calls.size.should eq(1)
      call_data = JSON.parse(calls.first.data)
      call_data["status"].as_s.should eq("done")
      call_data["proposed_by"].as_s.should eq("assistant")
      call_data["metadata"].as_h["tool_call_id"].as_s.should eq("tc_1")
      call_data["metadata"].as_h["run_id"].as_s.should eq("run_9")
      graph.objects(type: "capability_approval").size.should eq(1)
      graph.objects(type: "capability_result").size.should eq(1)
      graph.relations.any? { |rel| rel.type == "produces_result" }.should be_true
    end
  end

  it "holds a non-auto-approvable call for explicit approval" do
    with_gateway_runtime do |_store, graph, _rt|
      LlmToolsSupport.reset_seams
      Chronicle::Packs::ToolGateway.register_local_capability(
        "svc", "risky", ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} },
        description: "high-risk op", risk_class: "high", action_class: "R1",
      )
      spec = Chronicle::Packs::ToolGateway.get_capability_spec("svc.risky").not_nil!
      tool = Chronicle::Packs::ToolGateway.as_llm_tool(graph, spec, settings: Chronicle::Packs::ToolGateway::ToolGatewaySettings.new)

      result = tool.execute(%({"x": 1}), Crig::Tool::ToolContext.new)

      result.success?.should be_true
      result.output.render.should contain("held_for_approval")
      calls = graph.objects(type: "capability_call")
      calls.size.should eq(1)
      JSON.parse(calls.first.data)["status"].as_s.should eq("policy_checking")
      graph.objects(type: "capability_approval").size.should eq(0)
    end
  end

  it "registers gateway proxies in a Crig ToolSet and fails loud on unknown keys" do
    with_gateway_runtime do |_store, graph, _rt|
      LlmToolsSupport.reset_seams
      Chronicle::Packs::ToolGateway.register_web_fetch_capability
      tools = Chronicle::Packs::ToolGateway.llm_tools_for(graph, ["web.fetch_url"], settings: Chronicle::Packs::ToolGateway::ToolGatewaySettings.new)
      tools.size.should eq(1)
      tools.first.should be_a(Crig::ToolDyn)

      toolset = Crig::ToolSet.from_tools(tools)
      toolset.contains("web.fetch_url").should be_true
      toolset.call("web.fetch_url", %({"url": "https://x.test"}))

      expect_raises(Exception) do
        Chronicle::Packs::ToolGateway.llm_tools_for(graph, ["web.fetch_url", "typo.op"])
      end
    end
  end
end

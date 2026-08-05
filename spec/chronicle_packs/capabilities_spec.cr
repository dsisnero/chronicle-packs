require "spec"
require "../spec_helper"

# Reference web_fetch capability: read-only page fetch registered as a
# gateway capability (risk low, action R0) so it is policy-checkable and
# LLM-exposable. Live I/O runs through a host seam; an unset seam fails
# closed (the gateway never does ctx-less external I/O on its own).
#
# Note: class_property host seams (web_fetch_fetcher) are global, so each
# example resets them explicitly rather than relying on a helper's ensure.

module WebFetchSupport
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

include WebFetchSupport

describe "web.fetch_url capability" do
  it "registers web.fetch_url with low risk and R0 action" do
    with_gateway_runtime do |_store, _graph, _rt|
      reset_seams
      spec = Chronicle::Packs::ToolGateway.register_web_fetch_capability
      spec.provider_name.should eq("web")
      spec.capability_name.should eq("fetch_url")
      spec.risk_class.should eq("low")
      spec.action_class.should eq("R0")
      Chronicle::Packs::ToolGateway.registered_capability_keys.should contain("web.fetch_url")
    end
  end

  it "executes through the host fetcher seam when set" do
    with_gateway_runtime do |_store, _graph, _rt|
      reset_seams
      Chronicle::Packs::ToolGateway.register_web_fetch_capability
      Chronicle::Packs::ToolGateway.web_fetch_fetcher = ->(url : String, timeout : Float64) { {"<html>hello #{url}</html>", 200, url} }
      result = Chronicle::Packs::ToolGateway.execute_capability_fn("web", "fetch_url", {"url" => JSON::Any.new("https://example.com"), "timeout_seconds" => JSON::Any.new(10.0)})
      result["success"].as_bool.should be_true
      output = JSON.parse(result["output_data"].as_s)
      output["text"].as_s.should contain("hello https://example.com")
      output["status"].as_i.should eq(200)
      output["final_url"].as_s.should eq("https://example.com")
    end
  end

  it "fails closed when the host fetcher seam is unset" do
    with_gateway_runtime do |_store, _graph, _rt|
      reset_seams
      Chronicle::Packs::ToolGateway.register_web_fetch_capability
      result = Chronicle::Packs::ToolGateway.execute_capability_fn("web", "fetch_url", {"url" => JSON::Any.new("https://example.com")})
      result["success"].as_bool.should be_false
      result["error"].as_s.should contain("seam is unset")
    end
  end

  it "is auto-approvable under the default gateway policy (read-only, no side effects)" do
    settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new
    decision = Chronicle::Packs::ToolGateway.decide_policy("low", settings)
    decision.should eq("auto_approve")
  end
end

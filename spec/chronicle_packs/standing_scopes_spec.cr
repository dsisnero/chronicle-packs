require "spec"
require "../spec_helper"

# Tool Gateway standing scopes (ADR 0018): propose/promote/demote tool
# policies that let the action-class dimension auto-approve an R2 scope.

module StandingScopeSupport
  extend self

  def with_gateway_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    yield store, graph, rt
  end

  # Emit `count` prediction-then-decision event pairs with known ids.
  def emit_pairs(graph, count : Int32 = 8, predicted : String = "approve", actual : String = "approved")
    pairs = [] of Hash(String, JSON::Any)
    count.times do |i|
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "pred_#{i}", type: "prediction.recorded",
        actor: "product", caused_by: nil, payload: %({"prediction":"#{predicted}"}),
      ))
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "dec_#{i}", type: "decision.recorded",
        actor: "owner", caused_by: nil, payload: %({"verdict":"#{actual}"}),
      ))
      pairs << {
        "predicted_verdict" => JSON::Any.new(predicted),
        "actual_verdict"    => JSON::Any.new(actual),
        "prediction_ref"    => JSON::Any.new("pred_#{i}"),
        "decided_ref"       => JSON::Any.new("dec_#{i}"),
      }
    end
    pairs
  end
end

include StandingScopeSupport

describe "tool_gateway standing scopes" do
  it "scores prediction agreement and accuracy" do
    Chronicle::Packs::ToolGateway.pair_matched("approve", "approved").should be_true
    Chronicle::Packs::ToolGateway.pair_matched("reject", "edited").should be_true
    Chronicle::Packs::ToolGateway.pair_matched("approve", "rejected").should be_false
    pairs = [{"predicted_verdict" => JSON::Any.new("approve"), "actual_verdict" => JSON::Any.new("approved")}, {"predicted_verdict" => JSON::Any.new("approve"), "actual_verdict" => JSON::Any.new("rejected")}]
    Chronicle::Packs::ToolGateway.accuracy_percent(pairs).should eq(50)
  end

  it "proposes a candidate from qualifying prediction history" do
    with_gateway_runtime do |_store, graph, rt|
      pairs = emit_pairs(graph)
      result = Chronicle::Packs::ToolGateway.propose_standing_scope_fn(graph, capability_key: "web.fetch_url", action_class: "R2", prediction_pairs: pairs, proposed_by: "product")
      result["created"].as_bool.should be_true
      policies = graph.objects(type: "tool_policy")
      policies.size.should eq(1)
      JSON.parse(policies.first.data)["status"].as_s.should eq("candidate")
      graph.events.any? { |e| e.type == "tool_policy.proposed" }.should be_true

      expect_raises(Exception) do
        Chronicle::Packs::ToolGateway.propose_standing_scope_fn(graph, capability_key: "web.fetch_url", action_class: "R3", prediction_pairs: pairs, proposed_by: "product")
      end
    end
  end

  it "promotes a candidate and feeds R2 auto-approval" do
    with_gateway_runtime do |_store, graph, rt|
      pairs = emit_pairs(graph)
      result = Chronicle::Packs::ToolGateway.propose_standing_scope_fn(graph, capability_key: "web.fetch_url", action_class: "R2", prediction_pairs: pairs, proposed_by: "product")
      policy_id = JSON.parse(graph.objects(type: "tool_policy").first.data)["policy_id"].as_s

      promoted = Chronicle::Packs::ToolGateway.promote_tool_policy_fn(graph, policy_id, "owner", "approved for bounded fetch")
      promoted["changed"].as_bool.should be_true
      graph.events.any? { |e| e.type == "tool_policy.promoted" }.should be_true

      scope = Chronicle::Packs::ToolGateway.promoted_standing_scope_for(graph, "web.fetch_url", "R2")
      scope.should_not be_nil
      scope.not_nil!["accuracy_percent"].as_i.should eq(100)

      settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new
      decision = Chronicle::Packs::ToolGateway.decide_policy_detail("medium", settings, action_class: "R2", authority_ceiling: "R2", standing_scope: scope)
      decision["decision"].as_s.should eq("auto_approve")
      decision["granted_by"].as_s.should eq("action_authority")
    end
  end

  it "demotes a scope on accuracy degradation" do
    with_gateway_runtime do |_store, graph, rt|
      pairs = emit_pairs(graph)
      Chronicle::Packs::ToolGateway.propose_standing_scope_fn(graph, capability_key: "web.fetch_url", action_class: "R2", prediction_pairs: pairs, proposed_by: "product")
      policy_id = JSON.parse(graph.objects(type: "tool_policy").first.data)["policy_id"].as_s
      Chronicle::Packs::ToolGateway.promote_tool_policy_fn(graph, policy_id, "owner")

      demoted = Chronicle::Packs::ToolGateway.demote_tool_policy_fn(graph, policy_id, missed_prediction_refs: ["pred_2", "pred_5"], observed_accuracy_percent: 75, actor: "tool_policy_reliability_guard", reason: "reliability fell harmful")
      demoted["changed"].as_bool.should be_true
      policy = graph.objects(type: "tool_policy").first
      JSON.parse(policy.data)["status"].as_s.should eq("demoted")
      graph.events.any? { |e| e.type == "tool_policy.demoted" }.should be_true

      Chronicle::Packs::ToolGateway.promoted_standing_scope_for(graph, "web.fetch_url", "R2").should be_nil
    end
  end
end

require "spec"
require "../spec_helper"

# tool_policy_reliability_guard: a promoted standing scope (an automation
# grant) is demoted immediately on a harmful/stale reliability verdict,
# and recovery NEVER auto-re-promotes (fresh proposal + owner approval).

module StandingScopeGuardSupport
  extend self

  def with_gateway_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    yield store, graph, rt
  end

  def emit_pairs(graph, count : Int32 = 8)
    pairs = [] of Hash(String, JSON::Any)
    count.times do |i|
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "pred_#{i}", type: "prediction.recorded",
        actor: "product", caused_by: nil, payload: %({"prediction":"approve"}),
      ))
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "dec_#{i}", type: "decision.recorded",
        actor: "owner", caused_by: nil, payload: %({"verdict":"approved"}),
      ))
      pairs << {
        "predicted_verdict" => JSON::Any.new("approve"),
        "actual_verdict"    => JSON::Any.new("approved"),
        "prediction_ref"    => JSON::Any.new("pred_#{i}"),
        "decided_ref"       => JSON::Any.new("dec_#{i}"),
      }
    end
    pairs
  end

  def promote_scope(graph)
    tg = Chronicle::Packs::ToolGateway
    pairs = emit_pairs(graph)
    tg.propose_standing_scope_fn(graph, capability_key: "web.fetch_url", action_class: "R2", prediction_pairs: pairs, proposed_by: "product")
    policy_id = JSON.parse(graph.objects(type: "tool_policy").first.data)["policy_id"].as_s
    tg.promote_tool_policy_fn(graph, policy_id, "owner")
    policy_id
  end
end

include StandingScopeGuardSupport

describe "tool_policy_reliability_guard" do
  it "demotes a promoted standing scope on a harmful verdict" do
    with_gateway_runtime do |_store, graph, rt|
      promote_scope(graph)
      rt.run_until_idle
      policy_obj = graph.objects(type: "tool_policy").first

      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_1", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"tool_policy","artifact_id":"#{policy_obj.id}","verdict":"harmful","outcome_event_id":"oe_1"}),
      ))
      rt.run_until_idle

      data = JSON.parse(graph.objects(type: "tool_policy").first.data)
      data["status"].as_s.should eq("demoted")
      data["demotion_reason"].as_s.should contain("harmful")
      graph.events.any? { |e| e.type == "tool_policy.demoted" }.should be_true
    end
  end

  it "ignores non-tool_policy reliability and non-promoted policies" do
    with_gateway_runtime do |_store, graph, rt|
      promote_scope(graph)
      rt.run_until_idle
      policy_obj = graph.objects(type: "tool_policy").first

      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_2", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"skill_version","artifact_id":"skill_1","verdict":"harmful","outcome_event_id":"oe_2"}),
      ))
      rt.run_until_idle
      JSON.parse(graph.objects(type: "tool_policy").first.data)["status"].as_s.should eq("promoted")

      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_3", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"tool_policy","artifact_id":"#{policy_obj.id}","verdict":"weak","outcome_event_id":"oe_3"}),
      ))
      rt.run_until_idle
      JSON.parse(graph.objects(type: "tool_policy").first.data)["status"].as_s.should eq("promoted")
    end
  end

  it "does not auto-re-promote a demoted automation grant" do
    with_gateway_runtime do |_store, graph, rt|
      promote_scope(graph)
      rt.run_until_idle
      policy_obj = graph.objects(type: "tool_policy").first

      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_4", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"tool_policy","artifact_id":"#{policy_obj.id}","verdict":"harmful","outcome_event_id":"oe_4"}),
      ))
      rt.run_until_idle
      JSON.parse(graph.objects(type: "tool_policy").first.data)["status"].as_s.should eq("demoted")

      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_5", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"tool_policy","artifact_id":"#{policy_obj.id}","verdict":"supported","outcome_event_id":"oe_5"}),
      ))
      rt.run_until_idle
      JSON.parse(graph.objects(type: "tool_policy").first.data)["status"].as_s.should eq("demoted")
    end
  end

  it "evaluate_call_policy auto-approves R2 only with a promoted standing scope within the ceiling" do
    with_gateway_runtime do |_store, graph, rt|
      settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new
      promote_scope(graph)

      # Scope alone is not enough: the instance ceiling must be at least R2.
      no_ceiling = Chronicle::Packs::ToolGateway.evaluate_call_policy("web.fetch_url", "medium", "R2", settings, graph: graph)
      no_ceiling["decision"].as_s.should eq("hold")

      with_scope = Chronicle::Packs::ToolGateway.evaluate_call_policy("web.fetch_url", "medium", "R2", settings, graph: graph, authority_ceiling: "R2")
      with_scope["decision"].as_s.should eq("auto_approve")
      authority = with_scope["action_authority"].as_h
      authority["capability"].as_s.should eq("web.fetch_url")

      # Without the promoted scope, the raised ceiling still cannot grant R2.
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_6", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"tool_policy","artifact_id":"x","verdict":"harmful","outcome_event_id":"oe_6"}),
      ))
      rt.run_until_idle
      no_scope = Chronicle::Packs::ToolGateway.evaluate_call_policy("other.cap", "medium", "R2", settings, graph: graph, authority_ceiling: "R2")
      no_scope["decision"].as_s.should eq("hold")
    end
  end
end

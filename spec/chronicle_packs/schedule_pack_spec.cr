require "spec"
require "../spec_helper"

# Schedule Pack integration tests beyond the pack fixtures (upstream
# tests/test_schedule_pack.py).
#
# The fixture runner covers the pure time mechanics (fire/dedup/advance).
# These tests cover the composition seams: the reminder capability flowing
# through the Tool Gateway's LLM proxy (graph handle bound by the host), and
# the tick that later delivers it.
#
# Divergence (see parity.md): the ported gateway passes input_data only (no
# `execution_context` graph injection), so the reminder handler reads the
# graph bound via `Schedule::Capabilities.bound_graph` — the established
# capability seam. The rest of the flow matches upstream.

module SchedulePackSpecSupport
  extend self

  def with_reminder_runtime(&)
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Schedule::Capabilities.register_reminder_capability

    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(Chronicle::Packs::Fixtures::FixtureModel).new(model: Chronicle::Packs::Fixtures::FixtureModel.new, preamble: "")
    la = Chronicle::LogAgent(Chronicle::Packs::Fixtures::FixtureModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(Chronicle::Packs::Fixtures::FixtureModel).new(store: store, log_agent: la, graph: graph)

    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack, Chronicle::Packs::Fixtures._settings_hash(
      Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: ["low", "medium"])
    )).should be_true
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    rt.load_pack(Chronicle::Packs::Schedule.pack).should be_true

    Chronicle::Packs::Schedule::Capabilities.bound_graph = graph
    yield graph, rt
  ensure
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Schedule::Capabilities.bound_graph = nil
  end
end

include SchedulePackSpecSupport

describe Chronicle::Packs::Schedule do
  describe "reminder capability through the gateway, then the tick delivers" do
    it "creates a schedule via the gateway proxy and emits the approved candidate on the due tick" do
      with_reminder_runtime do |graph, rt|
        spec = Chronicle::Packs::ToolGateway.get_capability_spec("schedule.create_reminder").not_nil!
        tool = Chronicle::Packs::ToolGateway.as_llm_tool(
          graph, spec,
          settings: Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: ["low", "medium"]),
        )

        soon = (Time.utc + 1.hour).to_s("%Y-%m-%dT%H:%M:%SZ")
        ctx = Crig::Tool::ToolContext.new
        ctx.insert(Chronicle::Packs::ToolGateway::GatewayToolMetadata.new(tool_call_id: "tc_1", run_id: "run_9", behavior_name: "assistant"))
        result = tool.execute(%({"message":"Standup!","at":"#{soon}","channel":"chat"}), ctx)
        result.success?.should be_true, result.output.render
        rt.run_until_idle

        schedules = graph.objects(type: "schedule")
        schedules.size.should eq(1)
        JSON.parse(schedules.first.data)["kind"].as_s.should eq("once")

        calls = graph.objects(type: "capability_call")
        calls.should_not be_empty
        JSON.parse(calls.first.data)["capability_name"].as_s.should eq("create_reminder")
        JSON.parse(calls.first.data)["status"].as_s.should eq("done")

        # Time passes (edge-injected): the tick emits the approved candidate
        # and the Communication dispatcher marks it sent.
        later = (Time.utc + 2.hours).to_s("%Y-%m-%dT%H:%M:%SZ")
        ticks = Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, later)
        ticks.size.should eq(1)
        rt.run_until_idle

        cands = graph.objects(type: "comm_response_candidate")
        cands.size.should eq(1)
        cand_data = JSON.parse(cands.first.data)
        cand_data["content"].as_s.should eq("Standup!")
        cand_data["status"].as_s.should eq("sent")
        cand_data["metadata"].as_h["reminder"].as_bool.should be_true

        # 'once' auto-disabled; a later sweep does nothing.
        JSON.parse(graph.get_object(schedules.first.id).not_nil!.data)["enabled"].as_bool.should be_false
        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, later).should be_empty
      end
    end

    it "refuses a reminder with no time" do
      with_reminder_runtime do |graph, _rt|
        spec = Chronicle::Packs::ToolGateway.get_capability_spec("schedule.create_reminder").not_nil!
        tool = Chronicle::Packs::ToolGateway.as_llm_tool(
          graph, spec,
          settings: Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: ["low", "medium"]),
        )

        ctx = Crig::Tool::ToolContext.new
        ctx.insert(Chronicle::Packs::ToolGateway::GatewayToolMetadata.new(tool_call_id: "tc_1", run_id: "run_9", behavior_name: "assistant"))
        result = tool.execute(%({"message":"vague"}), ctx)
        result.success?.should be_true
        result.output.render.downcase.should contain("ok")
        graph.objects(type: "schedule").should be_empty
      end
    end
  end
end

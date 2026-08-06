require "spec"
require "../spec_helper"

# Memory promotion (P6, ADR 0018 posture): admission is storage; PROMOTION
# is a governed lifecycle transition earned from reliability evidence and
# resolved only by an explicit approver. Nothing promotes silently.

module PromotionSupport
  extend self

  def with_memory_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    yield store, graph, rt
  end

  def add_candidate(graph, text, category = "fact", source_ids = [] of String)
    graph.add_object("memory_candidate", JSON.build do |json|
      json.object do
        json.field "text", text
        json.field "confidence", 0.9
        json.field "category", category
        json.field "source_ids", JSON::Any.new(source_ids.map { |id| JSON::Any.new(id) })
        json.field "accepted", false
      end
    end)
  end

  def store_item(graph, rt, text)
    rt.run_until_idle
    add_candidate(graph, text)
    rt.run_until_idle
    graph.objects(type: "memory_item").first
  end

  def promote_item(graph, item, approver = "owner")
    Chronicle::Packs::MemoryGateway.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "supported", helped_outcomes: 2, evidence_event_ids: ["ev_1", "ev_2"], rationale: "repeated helped")
    proposal = graph.objects(type: "memory_promotion_proposal").first
    Chronicle::Packs::MemoryGateway.resolve_memory_promotion_fn(graph, JSON.parse(proposal.data)["proposal_id"].as_s, approve: true, approver: approver)
  end
end

describe "memory promotion" do
  it "proposes a promote from supported reliability evidence, idempotently" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      item = PromotionSupport.store_item(graph, rt, "the user prefers dark mode")
      mg = Chronicle::Packs::MemoryGateway

      result = mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "supported", helped_outcomes: 2, evidence_event_ids: ["ev_1", "ev_2"], rationale: "repeated helped")
      result["created"].as_bool.should be_true
      graph.objects(type: "memory_promotion_proposal").size.should eq(1)
      proposal_data = JSON.parse(graph.objects(type: "memory_promotion_proposal").first.data)
      proposal_data["direction"].as_s.should eq("promote")
      proposal_data["rule_id"].as_s.should eq("memory.promotion.reliability")

      again = mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "supported", helped_outcomes: 2, evidence_event_ids: ["ev_1", "ev_2"], rationale: "again")
      again["created"].as_bool.should be_false
      graph.objects(type: "memory_promotion_proposal").size.should eq(1)

      expect_raises(Exception) do
        mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "weak", helped_outcomes: 2, evidence_event_ids: ["ev_1"], rationale: "x")
      end
      expect_raises(Exception) do
        mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "supported", helped_outcomes: 1, evidence_event_ids: ["ev_1"], rationale: "x")
      end
    end
  end

  it "resolves a promote proposal via an explicit approver and emits memory.promoted" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      item = PromotionSupport.store_item(graph, rt, "the user prefers dark mode")
      mg = Chronicle::Packs::MemoryGateway
      mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "supported", helped_outcomes: 2, evidence_event_ids: ["ev_1", "ev_2"], rationale: "repeated helped")
      proposal_id = JSON.parse(graph.objects(type: "memory_promotion_proposal").first.data)["proposal_id"].as_s

      result = mg.resolve_memory_promotion_fn(graph, proposal_id, approve: true, approver: "owner", note: "yes")
      result["changed"].as_bool.should be_true
      result["resolution"].as_s.should eq("approved")
      JSON.parse(graph.objects(type: "memory_item").first.data)["promotion_status"].as_s.should eq("promoted")

      event = graph.events.find { |e| e.type == "memory.promoted" }
      event.should_not be_nil
      payload = JSON.parse(event.not_nil!.payload)
      payload["approver"].as_s.should eq("owner")
      payload["artifact_id"].as_s.should eq(item.id)
      payload["evidence_event_ids"].as_a.map(&.as_s).should contain("ev_1")
    end
  end

  it "rejects a proposal" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      item = PromotionSupport.store_item(graph, rt, "the user prefers dark mode")
      mg = Chronicle::Packs::MemoryGateway
      mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Promote, reliability_verdict: "supported", helped_outcomes: 2, evidence_event_ids: ["ev_1", "ev_2"], rationale: "repeated helped")
      proposal = graph.objects(type: "memory_promotion_proposal").first

      rejected = mg.resolve_memory_promotion_fn(graph, JSON.parse(proposal.data)["proposal_id"].as_s, approve: false, approver: "owner")
      rejected["resolution"].as_s.should eq("rejected")
      JSON.parse(graph.get_object(proposal.id).not_nil!.data)["status"].as_s.should eq("rejected")
      JSON.parse(graph.objects(type: "memory_item").first.data)["promotion_status"].as_s.should eq("admitted")
    end
  end

  it "demotes a promoted version on harmful evidence" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      item = PromotionSupport.store_item(graph, rt, "the user prefers dark mode")
      mg = Chronicle::Packs::MemoryGateway
      PromotionSupport.promote_item(graph, item)

      demote = mg.propose_memory_promotion_fn(graph, item.id, direction: Chronicle::Packs::MemoryGateway::PromotionDirection::Demote, reliability_verdict: "harmful", helped_outcomes: 0, evidence_event_ids: ["ev_9"], rationale: "turned harmful")
      demote["created"].as_bool.should be_true
      demote_proposal_id = JSON.parse(graph.objects(type: "memory_promotion_proposal").last.data)["proposal_id"].as_s

      resolved = mg.resolve_memory_promotion_fn(graph, demote_proposal_id, approve: true, approver: "owner")
      resolved["changed"].as_bool.should be_true
      JSON.parse(graph.objects(type: "memory_item").first.data)["promotion_status"].as_s.should eq("demoted")
      graph.events.any? { |e| e.type == "memory.demoted" }.should be_true
    end
  end

  it "memory_promotion_proposer generates proposals from reliability.changed" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      item = PromotionSupport.store_item(graph, rt, "the user prefers dark mode")
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "rl_1", type: "reliability.changed",
        actor: "eval_outcome", caused_by: nil,
        payload: %({"artifact_type":"memory_item","artifact_id":"#{item.id}","verdict":"supported","tallies":{"helped":2},"evidence_event_ids":["ev_1"]}),
      ))
      rt.run_until_idle
      proposals = graph.objects(type: "memory_promotion_proposal")
      proposals.size.should eq(1)
      JSON.parse(proposals.first.data)["direction"].as_s.should eq("promote")
    end
  end

  it "verify_memory_replay_fn earns replay.verified for a promoted item and fails loudly on replay-incomplete lineage" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      item = PromotionSupport.store_item(graph, rt, "the user prefers dark mode")
      PromotionSupport.promote_item(graph, item)
      mg = Chronicle::Packs::MemoryGateway

      verified = mg.verify_memory_replay_fn(graph, item.id)
      verified["created"].as_bool.should be_true
      graph.events.any? { |e| e.type == "replay.verified" }.should be_true
      again = mg.verify_memory_replay_fn(graph, item.id)
      again["created"].as_bool.should be_false
    end
  end

  it "verify_memory_replay_fn raises on reference_only lineage" do
    PromotionSupport.with_memory_runtime do |_store, graph, rt|
      rt.run_until_idle
      source = graph.add_object("source", JSON.build do |json|
        json.object do
          json.field "kind", "message"
          json.field "content", "raw"
          json.field "metadata", JSON::Any.new({"acquisition" => JSON::Any.new({"replay_mode" => JSON::Any.new("reference_only")})})
        end
      end)
      PromotionSupport.add_candidate(graph, "the user prefers dark mode", source_ids: [source.id])
      rt.run_until_idle
      item = graph.objects(type: "memory_item").first
      PromotionSupport.promote_item(graph, item)

      expect_raises(Chronicle::Packs::MemoryGateway::MemoryReplayIncompleteError) do
        Chronicle::Packs::MemoryGateway.verify_memory_replay_fn(graph, item.id)
      end
    end
  end
end

require "spec"
require "../spec_helper"

# P3 acceptance contract for canonical outcomes and artifact reliability
# (upstream tests/test_eval_outcome.py).
#
# The eval_outcome surface keeps terminal outcomes mutually exclusive per
# evaluation, corrects through supersession (never a duplicate terminal),
# exposes negative valence as queryable reliability (not player state), and
# demotes/restores artifacts in retrieval through the same reversible
# reliability handoff the skills pack uses.

module EvalOutcomeContractSpecSupport
  extend self

  def with_runtime(*packs, memory : Bool = false, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if memory
      rt.load_pack(Chronicle::Packs::MemoryGateway.pack, Chronicle::Packs::Fixtures._settings_hash(
        Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(backend_url: ":memory:", acceptance_threshold: 0.6)
      )).should be_true
    end
    packs.each { |pack| rt.load_pack(pack).should be_true }
    yield graph, rt
  end

  def artifact_and_evaluation(graph) : {String, String}
    artifact = graph.add_object("artifact", JSON.build do |json|
      json.object do
        json.field "kind", "report"
        json.field "title", "Acceptance artifact"
        json.field "content", "deterministic"
        json.field "status", "published"
      end
    end)
    evaluation = graph.add_object("evaluation", JSON.build do |json|
      json.object do
        json.field "subject_id", artifact.id
        json.field "subject_type", "artifact"
        json.field "judgment", "accepted"
        json.field "rationale", "owner accepted"
        json.field "evaluator", "owner:test"
      end
    end)
    {artifact.id, evaluation.id}
  end

  def seed_memories(graph, rt) : Array(String)
    ["Project alpha deadline Tuesday.", "Project alpha deadline Tuesday confirmed by owner."].each do |text|
      graph.add_object("memory_candidate", JSON.build do |json|
        json.object do
          json.field "text", text
          json.field "confidence", 0.95
          json.field "source_ids", JSON::Any.new([] of JSON::Any)
          json.field "observation_ids", JSON::Any.new([] of JSON::Any)
          json.field "category", "fact"
          json.field "accepted", false
        end
      end)
    end
    rt.run_until_idle
    graph.objects(type: "memory_item").map(&.id)
  end
end

include EvalOutcomeContractSpecSupport

describe "eval_outcome P3 acceptance contract" do
  it "keeps terminal outcomes mutually exclusive per evaluation and refuses a correction without supersession" do
    with_runtime(Chronicle::Packs::EvalOutcome.pack) do |graph, _rt|
      artifact_id, evaluation_id = artifact_and_evaluation(graph)
      first = Chronicle::Packs::EvalOutcome.record_terminal_outcome_fn(
        graph, "outcome.helped", evaluation_id, "accepted", "owner:test",
        artifact_id: artifact_id, artifact_type: "artifact",
      )
      first["created"].as_bool.should be_true
      Chronicle::Packs::EvalOutcome.record_terminal_outcome_fn(
        graph, "outcome.helped", evaluation_id, "retry", "owner:test",
        artifact_id: artifact_id, artifact_type: "artifact",
      )["created"].as_bool.should be_false
      expect_raises(Chronicle::Packs::PackError, /supersession/i) do
        Chronicle::Packs::EvalOutcome.record_terminal_outcome_fn(
          graph, "outcome.hurt", evaluation_id, "changed mind", "owner:test",
          artifact_id: artifact_id, artifact_type: "artifact",
        )
      end
      terminals = graph.events.select { |event| event.type.in?({"outcome.helped", "outcome.hurt", "outcome.neutral"}) }
      terminals.size.should eq(1)
    end
  end

  it "corrects through supersession without duplicating the old terminal" do
    with_runtime(Chronicle::Packs::EvalOutcome.pack) do |graph, rt|
      artifact_id, evaluation_id = artifact_and_evaluation(graph)
      Chronicle::Packs::EvalOutcome.record_terminal_outcome_fn(
        graph, "outcome.hurt", evaluation_id, "initial rejection", "owner:test",
        artifact_id: artifact_id, artifact_type: "artifact",
      )
      correction = Chronicle::Packs::EvalOutcome.supersede_evaluation_fn(
        graph, evaluation_id, "accept", "corrected after review", "owner:test",
      )
      rt.run_until_idle

      old_terminals = graph.objects(type: "outcome_record").select do |obj|
        data = JSON.parse(obj.data).as_h
        data["evaluation_id"]?.try(&.as_s?) == evaluation_id &&
          (data["outcome_type"]?.try(&.as_s?) || "").in?({"helped", "hurt", "neutral"})
      end
      old_terminals.size.should eq(1)

      supersession = correction["supersession"].as_h["data"].as_h
      supersession["outcome_type"].as_s.should eq("superseded")
      supersession["superseding_version"].as_s.should eq(correction["replacement_evaluation"].as_h["id"].as_s)
      correction["terminal"].as_h["data"].as_h["outcome_type"].as_s.should eq("helped")
    end
  end

  it "exposes negative valence as queryable reliability, never player state" do
    with_runtime(Chronicle::Packs::EvalOutcome.pack) do |graph, rt|
      artifact_id, evaluation_id = artifact_and_evaluation(graph)
      Chronicle::Packs::EvalOutcome.record_terminal_outcome_fn(
        graph, "outcome.hurt", evaluation_id, "verified failure", "owner:test",
        artifact_id: artifact_id, artifact_type: "tool_policy", artifact_version: "1",
      )
      rt.run_until_idle
      reliability = Chronicle::Packs::EvalOutcome.get_reliability_fn(graph, artifact_id).not_nil!
      reliability["verdict"].as_s.should eq("harmful")
      reliability["eligible"].as_bool.should be_false
      reliability["tallies"].as_h["hurt"].as_i.should eq(1)
      forbidden = {"score", "points", "badge", "level", "player"}
      reliability.keys.each { |key| forbidden.includes?(key).should be_false, "forbidden key #{key} leaked into reliability" }
    end
  end

  it "demotes a harmful memory in retrieval and restores it after a later helped" do
    with_runtime(Chronicle::Packs::EvalOutcome.pack, memory: true) do |graph, rt|
      items = seed_memories(graph, rt)
      items.size.should eq(2)
      target_id = items[0]

      Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
        graph, "reject", "memory caused a wrong action", "owner:test",
        artifact_id: target_id, artifact_type: "memory_item",
      )
      rt.run_until_idle

      harmful = Chronicle::Packs::EvalOutcome.get_reliability_fn(graph, target_id).not_nil!
      harmful["verdict"].as_s.should eq("harmful")

      ranked = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "project alpha deadline Tuesday", min_score: 0.0)
      target_row = ranked.find { |row| row["item_id"].as_s == target_id }.not_nil!
      peer_row = ranked.find { |row| row["item_id"].as_s != target_id }.not_nil!
      target_row["score"].as_f.should eq(target_row["raw_score"].as_f * 0.1)
      target_row["score"].as_f.should be < peer_row["score"].as_f
      JSON.parse(graph.get_object(target_id).not_nil!.data)["reliability_verdict"].as_s.should eq("harmful")

      Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
        graph, "accept", "later verified as useful", "owner:test",
        artifact_id: target_id, artifact_type: "memory_item",
      )
      rt.run_until_idle

      supported = Chronicle::Packs::EvalOutcome.get_reliability_fn(graph, target_id).not_nil!
      supported["verdict"].as_s.should eq("supported")
      restored = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "project alpha deadline Tuesday", min_score: 0.0)
      restored_row = restored.find { |row| row["item_id"].as_s == target_id }.not_nil!
      restored_row["score"].as_f.should eq(restored_row["raw_score"].as_f)
      JSON.parse(graph.get_object(target_id).not_nil!.data)["reliability_multiplier"].as_f.should eq(1.0)
    end
  end

  it "captures task and memory contradiction evaluations without a UI" do
    with_runtime(Chronicle::Packs::EvalOutcome.pack, memory: true) do |graph, rt|
      item_id = seed_memories(graph, rt)[0]
      task = graph.add_object("task", JSON.build do |json|
        json.object do
          json.field "title", "Close loop"
          json.field "status", "done"
          json.field "priority", "medium"
        end
      end)
      graph.add_object("evaluation", JSON.build do |json|
        json.object do
          json.field "subject_id", task.id
          json.field "subject_type", "task"
          json.field "judgment", "completed_successfully"
          json.field "rationale", "task completed"
          json.field "evaluator", "task_layer"
        end
      end)
      graph.add_object("evaluation", JSON.build do |json|
        json.object do
          json.field "subject_id", item_id
          json.field "subject_type", "memory_item"
          json.field "judgment", "contradicted"
          json.field "rationale", "new source disagrees"
          json.field "evaluator", "memory_layer"
          json.field "metadata", JSON::Any.new({"evidence_revision_id" => JSON::Any.new("revision:conflict-1")})
        end
      end)
      rt.run_until_idle

      graph.events.any? { |event| event.type == "outcome.helped" }.should be_true
      graph.events.any? { |event| event.type == "outcome.contradicted" }.should be_true
      Chronicle::Packs::EvalOutcome.get_reliability_fn(graph, item_id).not_nil!["verdict"].as_s.should eq("harmful")
    end
  end

  it "captures a gateway result acceptance evaluation as helped" do
    with_runtime(Chronicle::Packs::EvalOutcome.pack, Chronicle::Packs::ToolGateway.pack) do |graph, rt|
      result = graph.add_object("capability_result", JSON.build do |json|
        json.object do
          json.field "call_id", "capability_call#fixture"
          json.field "provider_name", "fixture"
          json.field "capability_name", "lookup"
          json.field "output_data", "accepted result"
          json.field "success", true
        end
      end)
      evaluation = graph.add_object("evaluation", JSON.build do |json|
        json.object do
          json.field "subject_id", result.id
          json.field "subject_type", "capability_result"
          json.field "judgment", "accepted"
          json.field "rationale", "owner accepted the executed result"
          json.field "evaluator", "owner:test"
        end
      end)
      rt.run_until_idle

      terminal = graph.objects(type: "outcome_record").select do |obj|
        JSON.parse(obj.data).as_h["evaluation_id"]?.try(&.as_s?) == evaluation.id
      end
      terminal.size.should eq(1)
      terminal.first.tap do |record|
        data = JSON.parse(record.data).as_h
        data["outcome_type"].as_s.should eq("helped")
        data["artifact_id"].as_s.should eq(result.id)
      end
    end
  end
end

require "spec"
require "../spec_helper"

# Memory Gateway Pack (packs/memory_gateway): the memory lifecycle — candidate
# evaluation, storage, retrieval, ranking, and reliability. Ported slice 1
# with a graph-backed store. Promotion/embedders/adapters/resolve are deferred.

module MemoryGatewaySpecSupport
  extend self

  def with_memory_runtime(settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::MemoryGateway.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    end
    yield store, graph, rt
  end

  def add_candidate(graph, text : String, confidence : Float64, category : String? = nil, source_ids : Array(String) = [] of String)
    graph.add_object("memory_candidate", JSON.build do |json|
      json.object do
        json.field "text", text
        json.field "confidence", confidence
        json.field "category", category ? JSON::Any.new(category) : JSON::Any.new(nil)
        json.field "source_ids", JSON::Any.new(source_ids.map { |id| JSON::Any.new(id) })
        json.field "accepted", false
      end
    end)
  end
end

include MemoryGatewaySpecSupport

describe Chronicle::Packs::MemoryGateway do
  describe "surface" do
    it "declares object types, relation types, behaviors, tools, and settings" do
      pack = Chronicle::Packs::MemoryGateway.pack
      pack.object_types.map(&.name).should contain("memory_item")
      pack.object_types.map(&.name).should contain("memory_retrieval")
      pack.relation_types.map(&.name).should contain("accepted_as")
      pack.behaviors.map(&.name).should contain("candidate_evaluator")
      pack.behaviors.map(&.name).should contain("memory_ranker")
      pack.tools.map(&.name).should contain("retrieve_memories")
      pack.settings_schema.should eq("MemoryGatewaySettings")
    end

    it "round-trips closed string sets through enum name-underscore serialization" do
      Chronicle::Packs::MemoryGateway::PromotionDirection::Demote.to_json.should eq(%("demote"))
      Chronicle::Packs::MemoryGateway::PromotionDirection.parse?("promote").should eq(Chronicle::Packs::MemoryGateway::PromotionDirection::Promote)
      Chronicle::Packs::MemoryGateway::PromotionDirection.parse?("unknown").should be_nil
      Chronicle::Packs::MemoryGateway::ReliabilityVerdict::Harmful.to_json.should eq(%("harmful"))
      Chronicle::Packs::MemoryGateway::ResolutionTier::AnnotatedEvidence.to_json.should eq(%("annotated_evidence"))
    end
  end

  describe "lexical_score" do
    it "computes max of Jaccard overlap and query-term coverage" do
      score = Chronicle::Packs::MemoryGateway::Backend.lexical_score("teal", "my favorite color is teal and I run a bakery")
      score.should be >= 0.2
      near = Chronicle::Packs::MemoryGateway::Backend.lexical_score("the user prefers dark mode", "the user prefers dark mode")
      near.should be_close(1.0, 0.01)
    end
  end

  describe "candidate_evaluator" do
    it "accepts high-confidence candidates with an evaluation object" do
      settings = Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.from_json(%({"acceptance_threshold":0.6}))
      with_memory_runtime(settings) do |_store, graph, rt|
        candidate = add_candidate(graph, "I prefer dark mode", 0.9, "preference")
        rt.run_until_idle
        evals = graph.objects(type: "evaluation")
        evals.size.should eq(1)
        JSON.parse(evals.first.data)["judgment"].as_s.should eq("accepted")
        candidate_data = JSON.parse(graph.get_object(candidate.id).not_nil!.data)
        candidate_data["accepted"].as_bool.should be_true
        graph.relations(type: "evaluates").size.should eq(1)
      end
    end

    it "rejects low-confidence candidates" do
      settings = Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.from_json(%({"acceptance_threshold":0.6}))
      with_memory_runtime(settings) do |_store, graph, rt|
        add_candidate(graph, "something vague", 0.3)
        rt.run_until_idle
        eval = graph.objects(type: "evaluation").first
        JSON.parse(eval.data)["judgment"].as_s.should eq("rejected")
      end
    end

    it "relieves the threshold for auto-accept priority categories" do
      settings = Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.from_json(%({"acceptance_threshold":0.9,"auto_accept_categories":["preference"],"auto_accept_min_confidence":0.5}))
      with_memory_runtime(settings) do |_store, graph, rt|
        add_candidate(graph, "I prefer tea", 0.6, "preference")
        rt.run_until_idle
        eval = graph.objects(type: "evaluation").first
        JSON.parse(eval.data)["judgment"].as_s.should eq("accepted")
      end
    end
  end

  describe "memory_writer" do
    it "promotes an accepted candidate into a memory_item" do
      with_memory_runtime do |_store, graph, rt|
        candidate = add_candidate(graph, "the user prefers dark mode", 0.9, "preference")
        rt.run_until_idle
        items = graph.objects(type: "memory_item")
        items.size.should eq(1)
        JSON.parse(items.first.data)["category"].as_s.should eq("preference")
        graph.relations(type: "accepted_as").size.should eq(1)
      end
    end
  end

  describe "memory_retriever and memory_ranker" do
    it "fulfills a retrieval request and ranks matching items" do
      with_memory_runtime do |_store, graph, rt|
        add_candidate(graph, "the user prefers dark mode for the editor", 0.9, "preference")
        add_candidate(graph, "the team ships weekly on fridays", 0.8, "fact")
        rt.run_until_idle
        graph.objects(type: "memory_item").size.should eq(2)

        graph.add_object("memory_retrieval_request", JSON.build do |json|
          json.object do
            json.field "query", "dark mode editor preference"
            json.field "top_k", 10
            json.field "min_score", 0.2
          end
        end)
        rt.run_until_idle

        retrieval = graph.objects(type: "memory_retrieval").first
        retrieval_data = JSON.parse(retrieval.data)
        retrieval_data["results_count"].as_i.should eq(1)
        graph.relations(type: "fulfilled_by").size.should eq(1)
        graph.relations(type: "ranked_in").size.should eq(1)
        rankings = graph.objects(type: "memory_ranking")
        rankings.size.should eq(1)
        JSON.parse(rankings.first.data)["rank"].as_i.should eq(1)
        graph.relations(type: "scored_by").size.should eq(1)
      end
    end
  end

  describe "memory_reliability_applier" do
    it "applies outcome reliability to a memory item" do
      with_memory_runtime do |_store, graph, rt|
        add_candidate(graph, "a durable memory", 0.9)
        rt.run_until_idle
        item = graph.objects(type: "memory_item").first
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 1_u64, id: "reliability_1", type: "reliability.changed",
          actor: "eval_outcome", caused_by: nil,
          payload: %({"artifact_type":"memory_item","artifact_id":"#{item.id}","verdict":"harmful","retrieval_multiplier":0.1}),
        ))
        rt.run_until_idle
        item_data = JSON.parse(graph.get_object(item.id).not_nil!.data)
        item_data["reliability_verdict"].as_s.should eq("harmful")
        item_data["reliability_multiplier"].as_f.should be_close(0.1, 0.001)
      end
    end
  end

  describe "retrieve_memories_fn" do
    it "returns outcome-adjusted ranked results" do
      with_memory_runtime do |_store, graph, rt|
        add_candidate(graph, "the user prefers dark mode in the editor", 0.9, "preference")
        rt.run_until_idle
        results = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "dark mode preference", top_k: 10, min_score: 0.2)
        results.size.should eq(1)
        results.first["text"].as_s.should contain("dark mode")
      end
    end
  end
end

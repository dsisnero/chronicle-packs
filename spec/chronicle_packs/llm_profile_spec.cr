require "spec"
require "../spec_helper"

# ensure_llm_extraction_profile_fn: provider configuration and graph policy
# are separate — enabling a provider after the deterministic seed mints a
# new profile version routing the model-only facets to semantic.llm.

module LlmProfileSupport
  extend self

  def with_semantic_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    yield store, graph, rt
  end
end

describe "ensure_llm_extraction_profile_fn" do
  it "mints a new profile version routing the model-only facets to semantic.llm" do
    LlmProfileSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      se = Chronicle::Packs::SemanticExtraction

      result = se.ensure_llm_extraction_profile_fn(graph, actor: "operator")
      result["profile_updated"].as_bool.should be_true

      profiles = graph.objects(type: "extraction_profile").sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }
      profiles.size.should eq(2)
      active_data = JSON.parse(profiles.last.data)
      active_data["status"].as_s.should eq("active")
      extractor_by_facet = active_data["extractor_by_facet"].as_h
      extractor_by_facet["event_mention"].as_s.should eq("semantic.llm@0.1.0")
      extractor_by_facet["relation_mention"].as_s.should eq("semantic.llm@0.1.0")
      active_data["default_facets"].as_a.map(&.as_s).should contain("event_mention")

      states = graph.objects(type: "annotation_extractor_state")
      states.any? { |obj| JSON.parse(obj.data)["extractor_id"].as_s == "semantic.llm" && JSON.parse(obj.data)["status"].as_s == "candidate" }.should be_true
    end
  end

  it "is a no-op when the LLM facets are already routed" do
    LlmProfileSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      se = Chronicle::Packs::SemanticExtraction
      se.ensure_llm_extraction_profile_fn(graph, actor: "operator")

      before = graph.objects(type: "extraction_profile").size
      again = se.ensure_llm_extraction_profile_fn(graph, actor: "operator")
      again["profile_updated"].as_bool.should be_false
      graph.objects(type: "extraction_profile").size.should eq(before)
    end
  end

  it "fails loud without an actor" do
    LlmProfileSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      expect_raises(Exception) do
        Chronicle::Packs::SemanticExtraction.ensure_llm_extraction_profile_fn(graph, actor: "")
      end
    end
  end
end

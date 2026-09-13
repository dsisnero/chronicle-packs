require "spec"
require "../spec_helper"

# LLM-backed annotation extractor (D025 stage two): semantic.llm@0.1.0
# behind the shared registry. The LLM proposes drafts; the extractor
# verifies byte-for-byte anchors, shapes bodies, and caps per facet — the
# model may not mint an annotation whose anchor does not exist. Provider
# calls ride a recorded completion boundary (durable events + idempotency-
# key replay).

module LlmExtractorSupport
  extend self

  def with_semantic_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    yield store, graph, rt
  end
end

describe "LLM extraction (recorded)" do
  it "verifies LLM-proposed drafts byte-for-byte and shapes facet bodies" do
    LlmExtractorSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      provider = ->(model : String, input : String) {
        %([{"facet":"entity_mention","exact":"Acme Corp","body":{"kind":"organization","normalized":"acme corp"},"confidence":0.9},{"facet":"assertion","exact":"prefers dark mode","body":{"text":"prefers dark mode"},"modality":"stated","polarity":"positive"}])
      }
      completion = Chronicle::Packs::SemanticExtraction::RecordedCompletionService.new(graph, "test-model", provider)
      extractor = Chronicle::Packs::SemanticExtraction::Extractors::LLMExtractorV1.new(provider: completion, model: "test-model")

      drafts = extractor.extract("Alice prefers dark mode and works at Acme Corp.", {} of String => JSON::Any, ["entity_mention", "assertion"])
      facets = drafts.map(&.facet)
      facets.should contain("entity_mention")
      facets.should contain("assertion")
      entity = drafts.find { |d| d.facet == "entity_mention" }.not_nil!
      entity.exact.should eq("Acme Corp")
      entity.body["kind"]?.try(&.as_s?).should eq("organization")
      entity.body["normalized"]?.try(&.as_s?).should eq("acme corp")
      assertion = drafts.find { |d| d.facet == "assertion" }.not_nil!
      assertion.start.should be >= 0
      assertion.end.should eq(assertion.start + "prefers dark mode".size)
    end
  end

  it "drops proposed spans that do not exist verbatim in the content" do
    LlmExtractorSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      provider = ->(model : String, input : String) {
        %([{"facet":"entity_mention","exact":"Acme Corp","body":{"kind":"organization"}}])
      }
      completion = Chronicle::Packs::SemanticExtraction::RecordedCompletionService.new(graph, "test-model", provider)
      extractor = Chronicle::Packs::SemanticExtraction::Extractors::LLMExtractorV1.new(provider: completion, model: "test-model")

      drafts = extractor.extract("Alice works at a different place.", {} of String => JSON::Any, ["entity_mention"])
      drafts.should be_empty
    end
  end

  it "clamps provider confidence instead of amplifying it" do
    LlmExtractorSupport.with_semantic_runtime do |_store, graph, _rt|
      provider = ->(model : String, input : String) {
        %([{"facet":"assertion","exact":"prefers dark mode","body":{"text":"prefers dark mode"},"confidence":9.0}])
      }
      completion = Chronicle::Packs::SemanticExtraction::RecordedCompletionService.new(graph, "test-model", provider)
      extractor = Chronicle::Packs::SemanticExtraction::Extractors::LLMExtractorV1.new(provider: completion, model: "test-model")

      drafts = extractor.extract("Alice prefers dark mode.", {} of String => JSON::Any, ["assertion"])
      drafts.size.should eq(1)
      drafts.first.confidence.should eq(1.0)
    end
  end

  it "cannot anchor selected LLM extraction into excluded quoted history" do
    LlmExtractorSupport.with_semantic_runtime do |_store, graph, _rt|
      text = "Current launches Friday\nOn Thu, Bob wrote:\n> Old launches Monday"
      evidence = graph.add_object("activity_evidence", {
        "evidence_identity"    => JSON::Any.new("ev_selection"),
        "revision_id"          => JSON::Any.new("rev_selection"),
        "normalized_content"   => JSON::Any.new(text),
        "normalized_metadata"  => JSON::Any.new({} of String => JSON::Any),
        "source_category"      => JSON::Any.new("communication"),
        "status"               => JSON::Any.new("current"),
        "acquired_at_event_id" => JSON::Any.new("evt_selection"),
      }.to_json)
      provider = ->(model : String, input : String) {
        %([{"facet":"relation_mention","exact":"Current launches Friday","body":{"subject":"Current","predicate":"launches","object":"Friday"}},{"facet":"relation_mention","exact":"Old launches Monday","body":{"subject":"Old","predicate":"launches","object":"Monday"}}])
      }
      completion = Chronicle::Packs::SemanticExtraction::RecordedCompletionService.new(graph, "test-model", provider)
      extractor = Chronicle::Packs::SemanticExtraction::Extractors::LLMExtractorV1.new(provider: completion, model: "test-model")
      Chronicle::Packs::SemanticExtraction::Extractors.register_annotation_extractor(extractor, replace: true)
      selected = "Current launches Friday"
      result = Chronicle::Packs::SemanticExtraction.run_annotation_extraction(
        graph, evidence,
        settings: Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new,
        requested_facets: ["relation_mention"], extractor_ref: "semantic.llm@0.1.0",
        selection_id: "current-only",
        content_segments: [{"start" => JSON::Any.new(0), "end" => JSON::Any.new(selected.size), "exact_hash" => JSON::Any.new(Digest::SHA256.hexdigest(selected))}],
      )
      ids = result["annotations"].as_a.map(&.as_s)
      ids.size.should eq(1)
      annotation_data = JSON.parse(graph.get_object(ids.first).not_nil!.data)
      annotation_data["selector"].as_h["exact"].as_s.should eq(selected)
      annotation_data["metadata"].as_h["selection_id"].as_s.should eq("current-only")
    end
  end

  it "records and replays completion calls by idempotency key" do
    LlmExtractorSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      calls = 0
      provider = ->(model : String, input : String) {
        calls += 1
        raise "provider called twice" if calls > 1

        %([{"facet":"assertion","exact":"prefers dark mode","body":{"text":"prefers dark mode"}}])
      }
      completion = Chronicle::Packs::SemanticExtraction::RecordedCompletionService.new(graph, "test-model", provider)
      metadata = {} of String => JSON::Any

      first = completion.structured("CONTENT\nAlice prefers dark mode", "prompt_hash_1", metadata)
      first.should contain("prefers dark mode")
      replayed = completion.structured("CONTENT\nAlice prefers dark mode", "prompt_hash_1", metadata)
      replayed.should eq(first)

      graph.events.count { |e| e.type == "llm.requested" }.should eq(1)
      graph.events.count { |e| e.type == "llm.responded" }.should eq(1)
    end
  end

  it "build_llm_extractor registers semantic.llm and fails loud without a provider or record" do
    LlmExtractorSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"llm_model":"test-model"}))
      provider = ->(model : String, input : String) { "[]" }
      extractor = se.build_llm_extractor(settings, graph, provider: provider)
      extractor.extractor_id.should eq("semantic.llm")
      Chronicle::Packs::SemanticExtraction::Extractors.get_annotation_extractor("semantic.llm", "0.1.0").should be_a(Chronicle::Packs::SemanticExtraction::Extractors::LLMExtractorV1)

      expect_raises(Exception) do
        se.build_llm_extractor(settings, graph, provider: nil)
      end
    end
  end
end

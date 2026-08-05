require "spec"
require "digest"
require "../spec_helper"

# Semantic Extraction Pack (packs/semantic_extraction): the shared annotation
# layer. Slice 1: the deterministic zero-key floor (DeterministicExtractorV1),
# facet bodies, the seeded extraction_profile, and the eager annotate pipeline
# with cache idempotency. Procedures/LLM/selection/promotion are deferred.

module SemanticExtractionSpecSupport
  extend self

  def with_semantic_runtime(settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    end
    yield store, graph, rt
  end

  def ingest_evidence(graph, content : String, source_surface_id : String = "chat/sess_1", category : String = "communication", path : String = "export")
    item = graph.add_object("acquired_item", JSON.build do |json|
      json.object do
        json.field "source_surface_id", source_surface_id
        json.field "dedup_key", "dedup_#{content.hash.abs}"
        json.field "source_ref", "msg_1"
        json.field "source_hash", "0" * 64
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "media_type", "text/plain"
        json.field "importer_id", "chatgpt_export"
        json.field "importer_version", "1.0.0"
      end
    end)
    graph.add_object("acquired_content", JSON.build do |json|
      json.object do
        json.field "acquired_item_id", item.id
        json.field "normalized_content", content
        json.field "normalized_metadata", {} of String => JSON::Any
        json.field "source_category", category
        json.field "connection_path", path
        json.field "is_fixture", true
      end
    end)
  end
end

include SemanticExtractionSpecSupport

describe Chronicle::Packs::SemanticExtraction do
  describe "surface" do
    it "declares object types, relation types, behaviors, tools, and settings" do
      pack = Chronicle::Packs::SemanticExtraction.pack
      pack.object_types.map(&.name).should contain("semantic_annotation")
      pack.object_types.map(&.name).should contain("extraction_profile")
      pack.relation_types.map(&.name).should contain("annotation_for")
      pack.behaviors.map(&.name).should contain("annotate_evidence")
      pack.tools.map(&.name).should contain("extract_annotations")
      pack.settings_schema.should eq("SemanticExtractionSettings")
    end
  end

  describe "DeterministicExtractorV1" do
    it "extracts entities, assertions, preferences, questions, temporals, and topic tags" do
      extractor = Chronicle::Packs::SemanticExtraction::Extractors::DeterministicExtractorV1.new
      content = "I met Jane at Acme Corp.\nWhat time is the meeting on March 5 2026?\nI prefer tea."
      drafts = extractor.extract(content, {} of String => JSON::Any, facets: Chronicle::Packs::SemanticExtraction::Facets::V1_IMPLEMENTED_FACETS)

      facets = drafts.map(&.facet).to_set
      facets.should contain("entity_mention")
      facets.should contain("preference_expression")
      facets.should contain("question")
      facets.should contain("temporal_expression")
      entity = drafts.find { |d| d.facet == "entity_mention" }
      entity.not_nil!.body["kind"]?.try(&.as_s?).should eq("proper_noun")
    end

    it "is byte-deterministic and capped per facet" do
      extractor = Chronicle::Packs::SemanticExtraction::Extractors::DeterministicExtractorV1.new(max_annotations_per_facet: 2)
      content = "One. Two. Three. Four. Five assertions to extract."
      drafts = extractor.extract(content, {} of String => JSON::Any, facets: ["assertion"])
      drafts.count { |d| d.facet == "assertion" }.should be <= 2
    end
  end

  describe "validate_body" do
    it "type-checks a facet body against its schema" do
      body = Chronicle::Packs::SemanticExtraction.validate_body("temporal_expression", JSON.parse(%({"text":"March 5 2026","normalized":"2026-03-05","precision":"day"})).as_h)
      body["normalized"].as_s.should eq("2026-03-05")
      body = Chronicle::Packs::SemanticExtraction.validate_body("namespaced.facet", JSON.parse(%({"free":"form"})).as_h)
      body["free"].as_s.should eq("form")
    end
  end

  describe "seed_extraction_profile" do
    it "seeds extraction_profile v1 on pack load" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        profiles = graph.objects(type: "extraction_profile")
        active = profiles.find { |obj| JSON.parse(obj.data)["status"].as_s == "active" }
        active.should_not be_nil
      end
    end
  end

  describe "annotate_evidence" do
    it "extracts annotations eagerly and records a run + coverage" do
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"max_annotations_per_facet":50}))
      with_semantic_runtime(settings) do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Jane prefers dark mode.\nWhat is the deadline on March 5 2026? Contact alice@acme.com.")
        rt.run_until_idle

        annotations = graph.objects(type: "semantic_annotation")
        annotations.size.should be >= 3
        runs = graph.objects(type: "extraction_run")
        runs.size.should eq(1)
        JSON.parse(runs.first.data)["status"].as_s.should eq("completed")
        coverages = graph.objects(type: "extraction_coverage")
        coverages.size.should eq(1)
        graph.relations(type: "annotation_for").size.should eq(annotations.size)
      end
    end

    it "is cache-idempotent on the same extractor identity" do
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"max_annotations_per_facet":50}))
      with_semantic_runtime(settings) do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Jane prefers dark mode.\nWhat is the deadline on March 5 2026? Contact alice@acme.com.")
        rt.run_until_idle
        ingest_evidence(graph, "Jane prefers dark mode.\nWhat is the deadline on March 5 2026? Contact alice@acme.com.")
        rt.run_until_idle

        graph.objects(type: "extraction_run").size.should eq(1)
        graph.objects(type: "semantic_annotation").size.should be >= 2
      end
    end
  end
end

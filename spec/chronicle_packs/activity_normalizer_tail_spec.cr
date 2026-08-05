require "spec"
require "digest"
require "../spec_helper"

# Activity Normalizer tail: the shared annotation layer (ADR 0026 step 2)
# and the compatibility projectors, enabled by the semantic_extraction port.

module ActivityNormalizerTailSpecSupport
  extend self

  def with_both_runtime(an_settings = nil, se_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if an_settings
      rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(an_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    end
    if se_settings
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack, JSON.parse(se_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    end
    yield store, graph, rt
  end

  def emit_annotation(graph, rt, facet : String, text : String, revision_id : String = "rev_1", evidence_id : String = "evidence_1", evidence_identity : String = "ev_1", ordinal : Int32 = 0, extractor_id : String = "activity.structure", body_fields = {} of String => JSON::Any)
    body = {"text" => JSON::Any.new(text)}.merge(body_fields)
    graph.emit(Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "annot_#{ordinal}", type: "object.created",
      actor: "system", caused_by: nil,
      payload: JSON.build do |json|
        json.object do
          json.field "id", "semantic_annotation_#{ordinal}"
          json.field "type", "semantic_annotation"
          json.field "data" do
            json.object do
              json.field "annotation_identity", "annot_#{ordinal}"
              json.field "facet", facet
              json.field "body", JSON::Any.new(body)
              json.field "evidence_id", evidence_id
              json.field "evidence_identity", evidence_identity
              json.field "revision_id", revision_id
              json.field "extractor_id", extractor_id
              json.field "extractor_version", "0.2.0"
              json.field "config_hash", "0" * 64
              json.field "status", "active"
              json.field "confidence", 0.8
              json.field "metadata", JSON::Any.new({"ordinal" => JSON::Any.new(ordinal)})
            end
          end
        end
      end,
    ))
  end
end

include ActivityNormalizerTailSpecSupport

describe "activity_normalizer ADR 0026 annotation layer" do
  it "registers the structure annotation extractor at the shared registry" do
    extractor = Chronicle::Packs::SemanticExtraction::Extractors.get_annotation_extractor("activity.structure", "0.2.0")
    extractor.extractor_id.should eq("activity.structure")
    extractor.implemented_facets.should contain("activity.preference")
  end

  it "extracts annotation drafts with the activity.* facet names and anchors" do
    extractor = Chronicle::Packs::ActivityNormalizer::AnnotationExtractor::StructureAnnotationExtractor.new
    drafts = extractor.extract("preference: dark mode\ntask: ship the report", {} of String => JSON::Any, facets: extractor.implemented_facets)
    drafts.any? { |d| d.facet == "activity.preference" }.should be_true
    drafts.any? { |d| d.facet == "activity.task" }.should be_true
    preference = drafts.find { |d| d.facet == "activity.preference" }
    preference.not_nil!.body["text"].as_s.should eq("dark mode")
    preference.not_nil!.start.should be >= 0
  end

  it "projects activity.structure annotations into legacy candidates" do
    with_both_runtime do |_store, graph, rt|
      rt.run_until_idle
      emit_annotation(graph, rt, "activity.preference", "dark mode", body_fields: {"preference" => JSON::Any.new("dark mode")})
      emit_annotation(graph, rt, "activity.task", "ship the report", ordinal: 1, body_fields: {"title" => JSON::Any.new("ship the report")})
      rt.run_until_idle

      preferences = graph.objects(type: "preference_candidate")
      preferences.size.should eq(1)
      JSON.parse(preferences.first.data)["candidate_identity"].as_s.should match(/^candidate_/)
      JSON.parse(preferences.first.data)["preference"].as_s.should eq("dark mode")
      tasks = graph.objects(type: "task_candidate")
      tasks.size.should eq(1)
      graph.relations(type: "projected_from_annotation").size.should eq(2)
      graph.relations(type: "extracted_from").size.should eq(2)
    end
  end

  it "select_shared_extraction routes activity.* facets to the annotation layer" do
    with_both_runtime do |_store, graph, rt|
      rt.run_until_idle
      # seed produces v1 (from semantic_extraction); the select behavior
      # reacts to it and mints v2 routing activity.* facets.
      graph.add_object("extraction_profile", JSON.build do |json|
        json.object do
          json.field "profile_identity", "profile_1"
          json.field "version", 1
          json.field "status", "active"
          json.field "default_facets", ["assertion", "entity_mention", "preference_expression", "question", "temporal_expression"]
          json.field "facets_by_source_category", JSON::Any.new({"communication" => JSON::Any.new(["entity_mention".to_json, "question".to_json, "temporal_expression".to_json].map { |s| JSON.parse(s) })})
          json.field "extractor_by_facet", JSON::Any.new({} of String => JSON::Any)
          json.field "created_by", "semantic_extraction.seed"
        end
      end)
      rt.run_until_idle

      profiles = graph.objects(type: "extraction_profile")
      versions = profiles.map { |obj| JSON.parse(obj.data)["version"].as_i }
      versions.should contain(2)
      v2 = profiles.find { |obj| JSON.parse(obj.data)["version"].as_i == 2 }
      extractor_map = JSON.parse(v2.not_nil!.data)["extractor_by_facet"].as_h
      extractor_map["activity.preference"].as_s.should eq("activity.structure@0.2.0")
      JSON.parse(v2.not_nil!.data)["status"].as_s.should eq("active")
    end
  end

  it "migrates stack-owned profiles with the communication floor on pack load" do
    with_both_runtime(Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.from_json(%({"select_shared_extraction":false})), Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"seed_default_profile":false}))) do |_store, graph, rt|
      # Simulate a replayed store with a stack-owned v1 profile before
      # activity_normalizer loads.
      graph.add_object("extraction_profile", JSON.build do |json|
        json.object do
          json.field "profile_identity", "legacy_1"
          json.field "version", 1
          json.field "status", "active"
          json.field "default_facets", ["assertion"]
          json.field "facets_by_source_category", JSON::Any.new({} of String => JSON::Any)
          json.field "extractor_by_facet", JSON::Any.new({} of String => JSON::Any)
          json.field "created_by", "semantic_extraction.seed"
        end
      end)
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16, sequence: 99_u64, id: "pack_loaded_an", type: "pack.loaded",
        actor: "system", caused_by: nil,
        payload: %({"name":"activity_normalizer","version":"0.1.0"}),
      ))
      rt.run_until_idle

      profiles = graph.objects(type: "extraction_profile")
      versions = profiles.map { |obj| JSON.parse(obj.data)["version"].as_i }.sort
      versions.should contain(2)
      migrated = profiles.find { |obj| JSON.parse(obj.data)["version"].as_i == 2 }
      facets = JSON.parse(migrated.not_nil!.data)["facets_by_source_category"].as_h
      facets["communication"].as_a.map(&.as_s).should contain("temporal_expression")
    end
  end
end

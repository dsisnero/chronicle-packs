require "spec"
require "digest"
require "json"
require "../spec_helper"

# ADR 0026 integration contract. Translated from
# tests/test_shared_extraction_migration.py at vendor revision
# 6639a5385518ad49f74813373c85cf96eff9adc0.
module SharedExtractionMigrationSpecSupport
  extend self

  CONTENT = "Remember: Yohei ships small tools.\n" \
            "Preference: concise status updates.\n" \
            "TODO: publish the migration notes.\n" \
            "Skill: daily_repo_digest\n" \
            "Eval: the summary helped a lot.\n" \
            "My name is Yohei.\n"

  LEGACY_CANDIDATE_TYPES = ["preference_candidate", "task_candidate", "profile_candidate", "skill_candidate", "eval_candidate"]

  def acquire(graph : Chronicle::GraphProjection, dedup_key : String = "migration-1", text : String = CONTENT) : Nil
    digest = Digest::SHA256.hexdigest(text)
    item = graph.add_object("acquired_item", JSON.build do |json|
      json.object do
        json.field "source_surface_id", "surface_migration_test"
        json.field "provider_item_id", dedup_key
        json.field "dedup_key", dedup_key
        json.field "source_ref", "test:#{dedup_key}"
        json.field "source_hash", digest
        json.field "provider_time", "2026-07-10T00:00:00Z"
        json.field "replay_mode", "inline"
        json.field "replay_payload_ref", text
        json.field "replay_payload_hash", digest
        json.field "media_type", "text/plain"
        json.field "importer_id", "test"
        json.field "importer_version", "0.1.0"
      end
    end)
    graph.add_object("acquired_content", JSON.build do |json|
      json.object do
        json.field "acquired_item_id", item.id
        json.field "normalized_content", text
        json.field "normalized_metadata", {"role" => JSON::Any.new("user")}
        json.field "source_category", "ai_activity"
        json.field "connection_path", "pack"
        json.field "is_fixture", true
      end
    end)
  end

  def with_migrated_runtime(entity : Bool = false, &)
    store, graph, runtime = PackSpecRuntime.runtime
    runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    runtime.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    runtime.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    runtime.load_pack(Chronicle::Packs::Entity.pack).should be_true if entity
    yield store, graph, runtime
  ensure
    Chronicle::Packs::Entity.clear_entity_registry if entity
  end

  def compat_candidates(graph : Chronicle::GraphProjection, type : String) : Array(Chronicle::GraphObject)
    graph.objects(type: type).select do |object|
      metadata = JSON.parse(object.data)["metadata"]?.try(&.as_h?) || {} of String => JSON::Any
      metadata["projector"]?.try(&.as_s?) == "activity_normalizer.compat"
    end
  end

  def legacy_projection(graph : Chronicle::GraphProjection) : Array(String)
    entries = [] of String
    LEGACY_CANDIDATE_TYPES.each do |type|
      graph.objects(type: type).each do |object|
        data = JSON.parse(object.data)
        metadata = data["metadata"]?.try(&.as_h?) || {} of String => JSON::Any
        next if type == "profile_candidate" && metadata["projector"]?.try(&.as_s?) == "semantic_extraction.profile"
        entries << [type, data["candidate_identity"]?.try(&.as_s?) || "", data["text"]?.try(&.as_s?) || "", data["confidence"]?.try(&.as_f?).to_s || "", data["status"]?.try(&.as_s?) || ""].join("\x1f")
      end
    end
    graph.objects(type: "memory_candidate").each do |object|
      data = JSON.parse(object.data)
      observations = data["observation_ids"]?.try(&.as_a?) || [] of JSON::Any
      structure_owned = observations.empty? || observations.any? do |id|
        graph.get_object(id.as_s).try { |object| JSON.parse(object.data)["facet"]?.try(&.as_s?) == "activity.memory" } || false
      end
      entries << ["memory_candidate", data["text"]?.try(&.as_s?) || "", data["confidence"]?.try(&.as_f?).to_s || ""].join("\x1f") if structure_owned
    end
    entries.sort
  end

  def annotation_identities(graph : Chronicle::GraphProjection) : Array(String)
    graph.objects(type: "semantic_annotation").map { |object| JSON.parse(object.data)["annotation_identity"].as_s }.sort
  end
end

include SharedExtractionMigrationSpecSupport

describe "shared extraction migration" do
  it "disables direct writes and routes structure facts through annotations" do
    with_migrated_runtime do |_store, graph, runtime|
      runtime.run_until_idle
      acquire(graph)
      runtime.run_until_idle

      graph.objects(type: "extraction_record").should be_empty
      facets = graph.objects(type: "semantic_annotation").map { |object| JSON.parse(object.data)["facet"].as_s }.to_set
      {"activity.memory", "activity.preference", "activity.task", "activity.profile", "activity.skill", "activity.eval"}.each { |facet| facets.should contain(facet) }

      LEGACY_CANDIDATE_TYPES.each do |type|
        candidates = compat_candidates(graph, type)
        candidates.should_not be_empty
        candidates.each do |candidate|
          data = JSON.parse(candidate.data)
          data["status"].as_s.should eq("candidate")
          data["candidate_identity"].as_s.should_not be_empty
          annotation_id = data["metadata"].as_h["annotation_id"].as_s
          annotation_object = graph.get_object(annotation_id)
          annotation_object.should_not be_nil
          JSON.parse(annotation_object.not_nil!.data)["facet"].as_s.starts_with?("activity.").should be_true
        end
      end

      evidence = graph.objects(type: "activity_evidence").first
      content = JSON.parse(evidence.data)["normalized_content"].as_s
      graph.objects(type: "semantic_annotation").each do |annotation_object|
        selector = JSON.parse(annotation_object.data)["selector"].as_h
        content[selector["start"].as_i...selector["end"].as_i].should eq(selector["exact"].as_s)
      end
    end
  end

  it "uses the legacy candidate identities for compatibility projectors" do
    legacy_store, legacy_graph, legacy_runtime = PackSpecRuntime.runtime
    legacy_runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    legacy_settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(legacy_extraction_enabled: true)
    legacy_runtime.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(legacy_settings.to_json).as_h).should be_true
    acquire(legacy_graph)
    legacy_runtime.run_until_idle

    with_migrated_runtime do |_store, migrated_graph, migrated_runtime|
      migrated_runtime.run_until_idle
      acquire(migrated_graph)
      migrated_runtime.run_until_idle
      LEGACY_CANDIDATE_TYPES.each do |type|
        legacy_ids = legacy_graph.objects(type: type).map { |object| JSON.parse(object.data)["candidate_identity"].as_s }.to_set
        migrated_ids = compat_candidates(migrated_graph, type).map { |object| JSON.parse(object.data)["candidate_identity"].as_s }.to_set
        legacy_ids.should eq(migrated_ids)
        legacy_ids.should_not be_empty
      end
    end
  end

  it "is a fixed point when reingesting and explicitly reextracting migrated evidence" do
    with_migrated_runtime do |_store, graph, runtime|
      runtime.run_until_idle
      acquire(graph)
      runtime.run_until_idle
      projection_before = legacy_projection(graph)
      annotations_before = annotation_identities(graph)
      projection_before.should_not be_empty

      acquire(graph)
      runtime.run_until_idle
      evidence = graph.objects(type: "activity_evidence").first
      result = Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new)
      runtime.run_until_idle

      result["created"].as_bool.should be_false
      legacy_projection(graph).should eq(projection_before)
      annotation_identities(graph).should eq(annotations_before)
      annotations_before.size.should eq(annotations_before.to_set.size)
    end
  end

  it "preserves the legacy candidate projection across the migration boundary" do
    _store, graph, legacy_runtime = PackSpecRuntime.runtime
    legacy_runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    legacy_settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(legacy_extraction_enabled: true)
    legacy_runtime.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(legacy_settings.to_json).as_h).should be_true
    acquire(graph)
    legacy_runtime.run_until_idle
    projection_before = legacy_projection(graph)
    projection_before.should_not be_empty
    graph.objects(type: "semantic_annotation").should be_empty

    migrated_runtime = Chronicle::Runtime(PackModel).new(
      store: legacy_runtime.store,
      log_agent: legacy_runtime.log_agent,
      graph: graph,
    )
    migrated_runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    migrated_runtime.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    migrated_runtime.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    migrated_runtime.run_until_idle
    acquire(graph)
    migrated_runtime.run_until_idle
    evidence = graph.objects(type: "activity_evidence").first
    Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new)
    migrated_runtime.run_until_idle

    graph.objects(type: "semantic_annotation").should_not be_empty
    legacy_projection(graph).should eq(projection_before)
    projection_after = legacy_projection(graph)
    annotations_after = annotation_identities(graph)
    acquire(graph)
    migrated_runtime.run_until_idle
    Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new)
    migrated_runtime.run_until_idle
    legacy_projection(graph).should eq(projection_after)
    annotation_identities(graph).should eq(annotations_after)
  end

  it "has the entity pack consume annotations and retain canonical resolution" do
    Chronicle::Packs::Entity.clear_entity_registry
    with_migrated_runtime(entity: true) do |_store, graph, runtime|
      runtime.run_until_idle
      acquire(graph, dedup_key: "entity-1", text: "Yohei Nakajima met the team at Untapped Capital. Reach him at yohei@untapped.vc.")
      runtime.run_until_idle

      mentions = graph.objects(type: "entity_mention")
      mentions.should_not be_empty
      mentions.all? { |mention| JSON.parse(mention.data)["extraction_method"].as_s == "annotation" }.should be_true
      annotation_ids = mentions.map { |mention| JSON.parse(mention.data)["metadata"].as_h["annotation_id"].as_s }
      annotation_ids.size.should eq(annotation_ids.to_set.size)
      mentions.all? { |mention| !JSON.parse(mention.data)["entity_id"].as_s.empty? }.should be_true
      graph.objects(type: "entity").should_not be_empty

      before = {mentions.size, graph.objects(type: "entity").size}
      evidence = graph.objects(type: "activity_evidence").first
      Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new)
      runtime.run_until_idle
      {graph.objects(type: "entity_mention").size, graph.objects(type: "entity").size}.should eq(before)
    end
  end

  it "leaves raw-source entity extraction disabled by default" do
    Chronicle::Packs::Entity.clear_entity_registry
    store, graph, runtime = PackSpecRuntime.runtime
    runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    runtime.load_pack(Chronicle::Packs::Entity.pack).should be_true
    graph.add_object("source", %({"content":"Yohei Nakajima works with Untapped Capital.","kind":"note"}))
    runtime.run_until_idle
    graph.objects(type: "entity_mention").should be_empty
  ensure
    Chronicle::Packs::Entity.clear_entity_registry
  end
end

require "spec"
require "../spec_helper"

# Entity pack (packs/entity): canonical, deduped real-world entities.
# Ported from upstream packs/entity/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no API key.

module EntitySpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def entity_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "entity" / "manifest.toml"
  end

  def entity_settings(json : String) : Chronicle::Packs::Entity::EntitySettings
    Chronicle::Packs::Entity::EntitySettings.from_json(json)
  end

  def with_entity_runtime(custom_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if custom_settings
      rt.load_pack(Chronicle::Packs::Entity.pack, JSON.parse(custom_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::Entity.pack).should be_true
    end
    Chronicle::Packs::Entity.clear_entity_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Entity.clear_entity_registry
  end

  def add_entity(graph : Chronicle::GraphProjection, name : String, entity_type : String = "other", aliases : Array(String) = [] of String, identifiers : Hash(String, String) = {} of String => String)
    graph.add_object("entity", JSON.build do |json|
      json.object do
        json.field "name", name
        json.field "entity_type", entity_type
        json.field "aliases", aliases
        json.field "identifiers", identifiers.to_h { |k, v| {k, JSON::Any.new(v)} }
        json.field "confidence", 0.8
        json.field "source_ids", [] of String
      end
    end)
  end
end

include EntitySpecSupport

describe Chronicle::Packs::Entity do
  describe "manifest-declared surface" do
    it "matches the upstream entity manifest" do
      pack = Chronicle::Packs::Entity.pack
      pack.name.should eq("entity")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["entity", "entity_mention", "merge_candidate", "merge_decision"]
      )
      pack.relation_types.map(&.name).should eq(
        ["mentions", "refers_to", "merge_candidate_for", "decided_by", "merged_into"]
      )
      pack.behaviors.map(&.name).should eq(
        ["entity_registry_recorder", "entity_extractor", "entity_mention_from_annotation",
         "entity_resolver", "merge_candidate_detector"]
      )
      pack.tools.map(&.name).should eq(["register_entity", "decide_merge"])
      pack.settings_schema.should eq("EntitySettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(entity_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Entity.pack)
    end
  end

  describe "similarity helpers" do
    it "computes edit distance ratio" do
      Chronicle::Packs::Entity.edit_distance_ratio("Alice Chan", "Alice Chan").should eq(1.0)
      Chronicle::Packs::Entity.edit_distance_ratio("alice chan", "Alice Chan").should eq(1.0)
      Chronicle::Packs::Entity.edit_distance_ratio("", "x").should eq(0.0)
      Chronicle::Packs::Entity.edit_distance_ratio("Acme", "Acme Inc").should be < 1.0
    end

    it "scores exact identifier overlap as definitive" do
      ids_a = {"email" => JSON::Any.new("alice@acme.com")}
      ids_b = {"email" => JSON::Any.new("ALICE@acme.com")}
      Chronicle::Packs::Entity.identifier_overlap_score(ids_a, ids_b).should eq(1.0)
      Chronicle::Packs::Entity.identifier_overlap_score(ids_a, {"email" => JSON::Any.new("bob@acme.com")}).should eq(0.0)
      Chronicle::Packs::Entity.identifier_overlap_score({} of String => JSON::Any, ids_b).should eq(0.0)
    end

    it "returns exact_identifier_match for shared identifiers" do
      sim = Chronicle::Packs::Entity.compute_similarity(
        "Alice Chan", [] of String, {"email" => JSON::Any.new("alice@acme.com")},
        "Alice C.", [] of String, {"email" => JSON::Any.new("alice@acme.com")}
      )
      sim.score.should eq(1.0)
      sim.reasons.should contain("exact_identifier_match")
    end
  end

  describe "entity_resolver" do
    it "creates a new entity for an unmatched mention" do
      with_entity_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"Alice Chan works at Acme Inc.","sender_ref":"x","channel":"chat"}))
        rt.run_until_idle
        # No entities registered yet — a mention resolves to a new entity.
        graph.add_object("entity_mention", %({"text":"Alice Chan","source_id":"s1","entity_type_hint":"person","confidence":0.9,"metadata":{}}))
        rt.run_until_idle

        entities = graph.objects(type: "entity")
        entities.size.should eq(1)
        JSON.parse(entities.first.data)["name"].as_s.should eq("Alice Chan")

        mentions = graph.objects(type: "entity_mention")
        JSON.parse(mentions.first.data)["entity_id"].as_s.should eq(entities.first.id)
        graph.relations(source: mentions.first.id, type: "refers_to").map(&.to_id).should eq([entities.first.id])
      end
    end

    it "links a mention to an existing entity by exact email identifier" do
      with_entity_runtime do |_store, graph, rt|
        add_entity(graph, "Alice Chan", "person", identifiers: {"email" => "alice@acme.com"})
        rt.run_until_idle

        graph.add_object("entity_mention", JSON.build do |json|
          json.object do
            json.field "text", "alice@acme.com"
            json.field "source_id", "s1"
            json.field "entity_type_hint", "person"
            json.field "confidence", 0.85
            json.field "metadata", {"email" => JSON::Any.new("alice@acme.com"), "normalized_name" => JSON::Any.new("Alice Chan")}
          end
        end)
        rt.run_until_idle

        graph.objects(type: "entity").size.should eq(1)
        mention = graph.objects(type: "entity_mention").first
        entity_id = JSON.parse(mention.data)["entity_id"].as_s
        entity_id.should eq(graph.objects(type: "entity").first.id)
        graph.relations(source: mention.id, type: "refers_to").map(&.to_id).should eq([entity_id])
      end
    end

    it "creates a new entity when similarity is below threshold" do
      with_entity_runtime(entity_settings(%({"resolution_similarity_threshold":0.7}))) do |_store, graph, rt|
        add_entity(graph, "Acme Corporation", "organization", aliases: ["Acme Corp"])
        rt.run_until_idle

        graph.add_object("entity_mention", %({"text":"Northwind Robotics","source_id":"s1","entity_type_hint":"organization","confidence":0.7,"metadata":{}}))
        rt.run_until_idle

        entities = graph.objects(type: "entity")
        entities.size.should eq(2)
      end
    end
  end

  describe "merge_candidate_detector" do
    it "creates a merge candidate for similar entities" do
      with_entity_runtime(entity_settings(%({"merge_candidate_threshold":0.8}))) do |_store, graph, rt|
        add_entity(graph, "Acme Corporation", "organization", aliases: ["Acme Corp"])
        rt.run_until_idle
        add_entity(graph, "Acme Corp", "organization")
        rt.run_until_idle

        candidates = graph.objects(type: "merge_candidate")
        candidates.size.should eq(1)
        data = JSON.parse(candidates.first.data)
        data["status"].as_s.should eq("pending")
        data["similarity_score"].as_f.should be >= 0.8

        graph.relations(type: "merge_candidate_for").size.should eq(2)
      end
    end

    it "skips identical-name entities that are the same object (no self-compare)" do
      with_entity_runtime do |_store, graph, rt|
        add_entity(graph, "Acme Corporation", "organization")
        rt.run_until_idle
        graph.objects(type: "merge_candidate").should be_empty
      end
    end
  end

  describe "entity_extractor" do
    it "extracts email, org, and person mentions from a source when enabled" do
      with_entity_runtime(entity_settings(%({"extract_from_raw_sources":true,"extract_urls_as_entities":true}))) do |_store, graph, rt|
        graph.add_object("source", %({"kind":"email","content":"alice@acme.com works at Acme Inc and posts to https://github.com/alice/widgets","channel":"email"}))
        rt.run_until_idle

        mentions = graph.objects(type: "entity_mention")
        mentions.size.should be >= 3
        hints = mentions.map { |m| JSON.parse(m.data)["entity_type_hint"].as_s }
        hints.should contain("person")
        hints.should contain("organization")
        hints.should contain("repo")

        source = graph.objects(type: "source").first
        graph.relations(source: source.id, type: "mentions").size.should eq(mentions.size)
      end
    end

    it "is disabled by default (shared extraction contract owns mentions)" do
      with_entity_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"email","content":"alice@acme.com works at Acme Inc","channel":"email"}))
        rt.run_until_idle
        graph.objects(type: "entity_mention").should be_empty
      end
    end
  end

  describe "entity_mention_from_annotation" do
    it "mints an EntityMention from a shared-layer annotation" do
      with_entity_runtime do |_store, graph, rt|
        graph.add_object("semantic_annotation", JSON.build do |json|
          json.object do
            json.field "facet", "entity_mention"
            json.field "status", "active"
            json.field "confidence", 0.9
            json.field "evidence_id", "ev_1"
            json.field "body", {"text" => JSON::Any.new("Alice Chan"), "kind" => JSON::Any.new("person")}
          end
        end)
        rt.run_until_idle

        mentions = graph.objects(type: "entity_mention")
        mentions.size.should eq(1)
        data = JSON.parse(mentions.first.data)
        data["text"].as_s.should eq("Alice Chan")
        data["entity_type_hint"].as_s.should eq("person")
        data["metadata"].as_h["annotation_id"].should_not be_nil
        data["extraction_method"].as_s.should eq("annotation")
      end
    end
  end

  describe "tools" do
    it "registers an entity and decides a merge" do
      with_entity_runtime do |_store, graph, rt|
        a = Chronicle::Packs::Entity.register_entity_fn(graph, "Acme Corporation", "organization", ["Acme Corp"], {"domain" => "acme.com"})
        rt.run_until_idle
        b = Chronicle::Packs::Entity.register_entity_fn(graph, "Acme Corp", "organization")
        rt.run_until_idle

        candidates = graph.objects(type: "merge_candidate")
        candidates.size.should eq(1)
        data = JSON.parse(candidates.first.data)
        a_id = data["entity_a_id"].as_s
        b_id = data["entity_b_id"].as_s

        decision = Chronicle::Packs::Entity.decide_merge_fn(graph, candidates.first.id, "accepted", a_id, "same org")
        decision.type.should eq("merge_decision")

        # The candidate status is patched and a merged_into relation is created.
        cand = graph.get_object(candidates.first.id)
        JSON.parse(cand.not_nil!.data)["status"].as_s.should eq("accepted")
        other = a_id == a_id ? b_id : a_id
        graph.relations(source: other, type: "merged_into").map(&.to_id).should eq([a_id])
      end
    end
  end
end

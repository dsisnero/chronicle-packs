require "spec"
require "digest"
require "../spec_helper"

# Semantic Extraction Pack (packs/semantic_extraction): the shared annotation
# layer. Slice 1: the deterministic zero-key floor (DeterministicExtractorV1),
# facet bodies, the seeded extraction_profile, and the eager annotate pipeline
# with cache idempotency. Procedures/LLM/selection/promotion are deferred.

module SemanticExtractionSpecSupport
  extend self

  def with_semantic_runtime(settings = nil, normalizer_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if normalizer_settings
      rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(normalizer_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    end
    if settings
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    end
    yield store, graph, rt
  end

  def ingest_evidence(graph, content : String, source_surface_id : String = "chat/sess_1", category : String = "communication", path : String = "export", role : String? = nil, subject_scope : String? = nil, dedup_key : String? = nil, provider_time : String? = nil)
    digest = Digest::SHA256.hexdigest(content)
    item = graph.add_object("acquired_item", JSON.build do |json|
      json.object do
        json.field "source_surface_id", source_surface_id
        json.field "dedup_key", dedup_key || "dedup_#{content.hash.abs}"
        json.field "source_ref", "msg_1"
        json.field "source_hash", digest
        json.field "provider_time", provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", digest
        json.field "media_type", "text/plain"
        json.field "importer_id", "chatgpt_export"
        json.field "importer_version", "1.0.0"
      end
    end)
    graph.add_object("acquired_content", JSON.build do |json|
      json.object do
        json.field "acquired_item_id", item.id
        json.field "normalized_content", content
        json.field "normalized_metadata", JSON::Any.new({
          "role"          => role ? JSON::Any.new(role) : JSON::Any.new(nil),
          "subject_scope" => subject_scope ? JSON::Any.new(subject_scope) : JSON::Any.new(nil),
        })
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

    it "routes communication through the bounded multi-subject floor" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        active = graph.objects(type: "extraction_profile").select { |obj| JSON.parse(obj.data)["status"].as_s == "active" }.last
        JSON.parse(active.data)["facets_by_source_category"].as_h["communication"].as_a.map(&.as_s).should eq(["entity_mention", "question", "temporal_expression"])
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

    it "does not project multi-subject communication into candidate behaviors" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "From: person@example.com\nCan we meet on 2026-08-01?", category: "communication", subject_scope: nil)
        rt.run_until_idle

        graph.objects(type: "semantic_annotation").should_not be_empty
        graph.objects(type: "memory_candidate").should be_empty
        graph.objects(type: "profile_candidate").should be_empty
        fired = graph.events.select { |event| event.type == "behavior.started" }.map { |event| JSON.parse(event.payload)["behavior"]?.try(&.as_s?) || "" }
        fired.any? { |name| name.ends_with?("project_profile_candidates") }.should be_false
        fired.any? { |name| name.ends_with?("project_memory_candidates") }.should be_false
        fired.any? { |name| name.ends_with?("project_structure_candidates") }.should be_false
      end
    end

    it "uses subject-self attribution for user-authored evidence" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "I prefer tea and I will visit Paris on 2026-08-01.", role: "user", subject_scope: "owner_profile")
        rt.run_until_idle

        graph.objects(type: "semantic_annotation").should_not be_empty
        graph.objects(type: "semantic_annotation").each do |ann|
          JSON.parse(ann.data)["attribution"].as_s.should eq("subject_self")
        end
      end
    end

    it "is byte deterministic and gives every annotation the complete envelope" do
      fingerprints = [] of String
      2.times do
        with_semantic_runtime do |_store, graph, rt|
          rt.run_until_idle
          content = "Yohei created BabyAGI on 2023-03-28. Maybe he might explore vector databases later."
          ingest_evidence(graph, content, category: "ai_activity", role: "assistant", subject_scope: "owner_profile", provider_time: "2026-07-10T00:00:00Z")
          rt.run_until_idle

          evidence = graph.objects(type: "activity_evidence").first
          rows = graph.objects(type: "semantic_annotation").map do |ann|
            data = JSON.parse(ann.data).as_h
            selector = data["selector"].as_h
            content.byte_slice(selector["start"].as_i, selector["end"].as_i - selector["start"].as_i).should eq(selector["exact"].as_s)
            data["evidence_id"].as_s.should eq(evidence.id)
            data["evidence_identity"].as_s.should eq(JSON.parse(evidence.data)["evidence_identity"].as_s)
            data["revision_id"].as_s.should_not be_empty
            {"identity" => data["annotation_identity"], "facet" => data["facet"], "body" => data["body"], "selector" => data["selector"], "confidence" => data["confidence"], "attribution" => data["attribution"], "modality" => data["modality"], "polarity" => data["polarity"], "event_time" => data["event_time"], "observation_time" => data["observation_time"]} of String => JSON::Any
          end
          rows.each do |row|
            row["confidence"].as_f.should be >= 0.0
            row["confidence"].as_f.should be <= 1.0
            row["attribution"].as_s.should eq("author_about_subject")
          end
          fingerprints << rows.sort_by { |row| row["identity"].as_s }.to_json
        end
      end
      fingerprints.uniq.size.should eq(1)
      fingerprints.first.should_not eq("[]")
    end

    it "marks hedged statements uncertain and normalizes temporal event time" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Maybe the launch might move to March 5 2026.", category: "ai_activity", role: "assistant")
        rt.run_until_idle

        rows = graph.objects(type: "semantic_annotation").map { |ann| JSON.parse(ann.data).as_h }
        rows.any? { |row| row["modality"].as_s == "uncertain" }.should be_true
        temporals = rows.select { |row| row["facet"].as_s == "temporal_expression" }
        temporals.should_not be_empty
        temporals.each do |row|
          row["event_time"].as_s.should eq(row["body"].as_h["normalized"].as_s)
        end
      end
    end

    it "fills only newly requested facets and records unsupported standard facets" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Alice prefers dark mode and asks about Tuesday.", category: "ai_activity", role: "assistant")
        rt.run_until_idle
        evidence = graph.objects(type: "activity_evidence").first
        before = graph.objects(type: "semantic_annotation").size

        incremental = Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new, requested_facets: Chronicle::Packs::SemanticExtraction::Facets::DEFAULT_EAGER_FLOOR + ["topic_tag"])
        incremental["created"].as_bool.should be_true
        incremental["executed_facets"].as_a.map(&.as_s).should eq(["topic_tag"])
        graph.objects(type: "semantic_annotation")[before..].each { |ann| JSON.parse(ann.data)["facet"].as_s.should eq("topic_tag") }

        unsupported = Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new, requested_facets: ["idea"])
        unsupported["executed_facets"].as_a.should be_empty
        coverage = Chronicle::Packs::SemanticExtraction.annotation_coverage_fn(graph, unsupported["run_id"].as_s).not_nil!.as_h
        coverage["skipped_facets"].as_a.any? { |entry| entry.as_h["facet"].as_s == "idea" && entry.as_h["reason"].as_s == "not_implemented" }.should be_true
      end
    end

    it "makes explicit reextraction and identical reacquisition no-ops" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        content = "Alice prefers dark mode and works from Denver."
        ingest_evidence(graph, content, category: "ai_activity", role: "assistant", dedup_key: "summary-1")
        rt.run_until_idle
        annotations = graph.objects(type: "semantic_annotation").size
        runs = graph.objects(type: "extraction_run").size
        evidence = graph.objects(type: "activity_evidence").first

        result = Chronicle::Packs::SemanticExtraction.extract_annotations_fn(graph, evidence.id, Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new)
        result["created"].as_bool.should be_false
        graph.objects(type: "semantic_annotation").size.should eq(annotations)
        graph.objects(type: "extraction_run").size.should eq(runs)

        ingest_evidence(graph, content, category: "ai_activity", role: "assistant", dedup_key: "summary-1")
        rt.run_until_idle
        graph.objects(type: "activity_evidence").size.should eq(1)
        graph.objects(type: "semantic_annotation").size.should eq(annotations)
      end
    end

    it "creates fresh annotations for a superseding evidence revision" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Alice prefers dark mode.", category: "ai_activity", role: "assistant", dedup_key: "summary-1")
        rt.run_until_idle
        first = graph.objects(type: "semantic_annotation").size

        ingest_evidence(graph, "Alice prefers dark mode. Alice mentors founders every week.", category: "ai_activity", role: "assistant", dedup_key: "summary-1")
        rt.run_until_idle
        evidences = graph.objects(type: "activity_evidence")
        evidences.size.should eq(2)
        evidences.map { |obj| JSON.parse(obj.data)["status"].as_s }.to_set.should eq(Set{"current", "superseded"})
        graph.objects(type: "semantic_annotation").size.should be > first
      end
    end

    it "records queryable coverage including visible truncation" do
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new(max_content_chars: 1_000)
      with_semantic_runtime(settings) do |_store, graph, rt|
        rt.run_until_idle
        content = "Alice prefers dark mode. " + ("filler " * 400)
        ingest_evidence(graph, content, category: "ai_activity", role: "assistant")
        rt.run_until_idle

        coverages = graph.objects(type: "extraction_coverage").map { |obj| JSON.parse(obj.data).as_h }
        coverages.should_not be_empty
        coverage = coverages.first
        coverage["content_chars_total"].as_i.should eq(content.size)
        coverage["content_chars_processed"].as_i.should eq(1_000)
        coverage["truncated"].as_bool.should be_true
        run = graph.get_object(coverage["run_id"].as_s).not_nil!
        JSON.parse(run.data)["run_identity"].as_s.should_not be_empty
      end
    end
  end

  describe "profile versioning and invalidation" do
    it "seeds the migration profile, versions owner policy, and rejects unknown facets" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        profiles = graph.objects(type: "extraction_profile").sort_by { |obj| JSON.parse(obj.data)["version"].as_i }
        profiles.map { |obj| JSON.parse(obj.data)["version"].as_i }.should eq([1, 2])
        profiles.map { |obj| JSON.parse(obj.data)["status"].as_s }.should eq(["superseded", "active"])

        result = Chronicle::Packs::SemanticExtraction.update_extraction_profile_fn(
          graph, facets_by_source_category: {"ai_activity" => ["assertion", "topic_tag"]},
          rationale: "narrow ai activity", created_by: "owner",
        )
        result["version"].as_i.should eq(3)
        graph.objects(type: "extraction_profile").select { |obj| JSON.parse(obj.data)["status"].as_s == "active" }.size.should eq(1)

        expect_raises(Chronicle::Packs::PackError, /unknown facet/) do
          Chronicle::Packs::SemanticExtraction.update_extraction_profile_fn(graph, default_facets: ["vibes"])
        end

        ingest_evidence(graph, "Alice prefers deterministic tools.", category: "ai_activity", role: "assistant")
        rt.run_until_idle
        run = graph.objects(type: "extraction_run").last
        JSON.parse(run.data)["requested_facets"].as_a.map(&.as_s).should eq(["assertion", "topic_tag"])
      end
    end

    it "invalidates deterministic provenance while retaining evidence and blocks future runs" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Alice prefers dark mode and works in Denver.", category: "ai_activity", role: "assistant", subject_scope: "owner_profile", dedup_key: "summary-1")
        rt.run_until_idle
        evidence_ids = graph.objects(type: "activity_evidence").map(&.id).to_set
        graph.objects(type: "semantic_annotation").should_not be_empty

        result = Chronicle::Packs::SemanticExtraction.invalidate_annotation_extractor_fn(graph, "semantic.deterministic", "0.1.0", reason: "bad heuristic")
        result["invalidated_annotations"].as_i.should be > 0
        graph.objects(type: "extraction_run").each do |run|
          data = JSON.parse(run.data)
          next unless data["extractor_id"].as_s == "semantic.deterministic"

          data["status"].as_s.should eq("invalidated")
        end
        graph.objects(type: "semantic_annotation").each do |ann|
          data = JSON.parse(ann.data)
          if data["extractor_id"].as_s == "semantic.deterministic"
            data["status"].as_s.should eq("invalidated")
            data["invalidation_reason"].as_s.should eq("bad heuristic")
          else
            data["status"].as_s.should eq("active")
          end
        end
        graph.objects(type: "activity_evidence").map(&.id).to_set.should eq(evidence_ids)
        graph.objects(type: "activity_evidence").each { |evidence| JSON.parse(evidence.data)["status"].as_s.should eq("current") }

        ingest_evidence(graph, "Another summary about Tokyo on 2026-01-02.", category: "ai_activity", role: "assistant", dedup_key: "summary-2")
        rt.run_until_idle
        graph.objects(type: "extraction_run").select { |run| JSON.parse(run.data)["extractor_id"].as_s == "semantic.deterministic" && JSON.parse(run.data)["status"].as_s == "completed" }.should be_empty
      end
    end
  end

  describe "layer boundaries" do
    it "chains projected candidates to their source annotations and evidence" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Alice prefers dark mode and works from Denver.", category: "ai_activity", role: "assistant", subject_scope: "owner_profile")
        rt.run_until_idle

        relations = graph.relations(type: "projected_from_annotation")
        relations.should_not be_empty
        annotation_ids = graph.objects(type: "semantic_annotation").map(&.id).to_set
        relations.each { |relation| annotation_ids.includes?(relation.to_id).should be_true }
      end
    end

    it "keeps extraction itself annotation-only when every projector is disabled" do
      extraction_settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new(
        mint_profile_candidates: false, mint_memory_candidates: false,
      )
      normalizer_settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(
        compat_candidate_projectors: false,
      )
      with_semantic_runtime(extraction_settings, normalizer_settings) do |_store, graph, rt|
        rt.run_until_idle
        ingest_evidence(graph, "Alice prefers dark mode and works from Denver.", category: "ai_activity", role: "assistant", subject_scope: "owner_profile")
        rt.run_until_idle

        graph.objects(type: "semantic_annotation").should_not be_empty
        graph.objects(type: "profile_candidate").each do |candidate|
          JSON.parse(candidate.data)["metadata"]?.try(&.as_h?.try(&.["projector"]?.try(&.as_s?))).should_not eq("semantic_extraction.profile")
        end
        graph.objects(type: "memory_candidate").each do |candidate|
          JSON.parse(candidate.data)["observation_ids"]?.should be_nil
        end
      end
    end
  end

  it "declares the complete standard facet set" do
    Chronicle::Packs::SemanticExtraction::Facets::STANDARD_FACETS.should eq([
      "entity_mention", "assertion", "question", "idea", "event_mention",
      "relation_mention", "preference_expression", "temporal_expression",
      "quantity_mention", "topic_tag",
    ])
  end
end

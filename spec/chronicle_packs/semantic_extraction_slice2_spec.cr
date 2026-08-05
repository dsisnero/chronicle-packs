require "spec"
require "../spec_helper"

# Semantic Extraction slice 2a: candidate projectors + profile/invalidation
# tools (self-contained on ported types).

module SemanticSlice2Support
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

  def emit_annotation(graph, rt, facet : String, text : String, revision_id : String = "rev_1", evidence_id : String = "evidence_1", evidence_identity : String = "ev_1", attribution : String = "unknown", modality : String = "stated", eligible : Bool = false, ordinal : Int32 = 0, kind : String? = nil, normalized : String? = nil)
    body = {"text" => JSON::Any.new(text)}
    body["kind"] = JSON::Any.new(kind) if kind
    body["normalized"] = JSON::Any.new(normalized) if normalized
    metadata = {"ordinal" => JSON::Any.new(ordinal)}
    metadata["profile_candidate_eligible"] = JSON::Any.new(true) if eligible
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
              json.field "extractor_id", "semantic.deterministic"
              json.field "extractor_version", "0.1.0"
              json.field "config_hash", "0" * 64
              json.field "status", "active"
              json.field "confidence", 0.8
              json.field "attribution", attribution
              json.field "modality", modality
              json.field "metadata", JSON::Any.new(metadata)
            end
          end
        end
      end,
    ))
  end

  def add_owner_evidence(graph, rt)
    graph.add_object("activity_evidence", JSON.build do |json|
      json.object do
        json.field "evidence_identity", "ev_1"
        json.field "evidence_id", "evidence_1"
        json.field "revision_id", "rev_1"
        json.field "revision_number", 1
        json.field "source_surface_id", "chat/sess_1"
        json.field "source_category", "communication"
        json.field "connection_path", "export"
        json.field "source_ref", "msg_1"
        json.field "importer_id", "i"
        json.field "importer_version", "1"
        json.field "status", "current"
        json.field "acquired_item_id", "acquired_item_1"
        json.field "acquired_content_id", "acquired_content_1"
        json.field "dedup_key", "d1"
        json.field "content_hash", "0" * 64
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "replay_complete", false
        json.field "media_type", "text/plain"
        json.field "acquired_at_event_id", "evt_1"
        json.field "normalized_content", "alice is @alice"
        json.field "normalized_metadata", JSON::Any.new({"subject_scope" => JSON::Any.new("owner_profile")})
      end
    end)
  end
end

include SemanticSlice2Support

describe "semantic_extraction slice 2a" do
  describe "project_profile_candidates" do
    it "mints a profile candidate from an eligible owner-profile handle annotation" do
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"mint_profile_candidates":true}))
      with_semantic_runtime(settings) do |_store, graph, rt|
        rt.run_until_idle
        evidence_obj = add_owner_evidence(graph, rt)
        rt.run_until_idle
        emit_annotation(graph, rt, "entity_mention", "@alice", attribution: "subject_self", eligible: true, kind: "handle", normalized: "@alice", evidence_id: evidence_obj.id)
        rt.run_until_idle

        candidates = graph.objects(type: "profile_candidate")
        candidates.size.should eq(1)
        JSON.parse(candidates.first.data)["attribute"].as_s.should eq("handle")
        graph.relations(type: "projected_from_annotation").size.should eq(1)
      end
    end
  end

  describe "project_memory_candidates" do
    it "mints a memory candidate from a stated assertion annotation" do
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"mint_memory_candidates":true}))
      with_semantic_runtime(settings) do |_store, graph, rt|
        rt.run_until_idle
        emit_annotation(graph, rt, "assertion", "the user prefers dark mode", modality: "stated")
        rt.run_until_idle

        candidates = graph.objects(type: "memory_candidate")
        candidates.size.should eq(1)
        JSON.parse(candidates.first.data)["observation_ids"].as_a.map(&.as_s).should contain("semantic_annotation_0")
        graph.relations(type: "projected_from_annotation").size.should eq(1)
      end
    end
  end

  describe "update_extraction_profile_fn" do
    it "mints the next version and supersedes the active profile" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        result = Chronicle::Packs::SemanticExtraction.update_extraction_profile_fn(graph, default_facets: ["assertion", "question"], rationale: "owner policy", created_by: "owner")
        result["ok"].as_bool.should be_true
        result["version"].as_i.should be > 1
        profiles = graph.objects(type: "extraction_profile")
        superseded = profiles.find { |obj| JSON.parse(obj.data)["status"].as_s == "superseded" }
        superseded.should_not be_nil
        active = profiles.find { |obj| JSON.parse(obj.data)["status"].as_s == "active" }
        JSON.parse(active.not_nil!.data)["version"].as_i.should eq(result["version"].as_i)

        expect_raises(Exception) do
          Chronicle::Packs::SemanticExtraction.update_extraction_profile_fn(graph, default_facets: ["not_a_facet"])
        end
      end
    end
  end

  describe "invalidate_annotation_extractor_fn" do
    it "disables the extractor and invalidates its runs, annotations, and candidates" do
      with_semantic_runtime do |_store, graph, rt|
        rt.run_until_idle
        emit_annotation(graph, rt, "assertion", "the user prefers dark mode", modality: "stated")
        rt.run_until_idle
        graph.objects(type: "semantic_annotation").size.should eq(1)

        result = Chronicle::Packs::SemanticExtraction.invalidate_annotation_extractor_fn(graph, "semantic.deterministic", "0.1.0", reason: "deprecated floor")
        result["ok"].as_bool.should be_true
        states = graph.objects(type: "annotation_extractor_state")
        states.size.should eq(1)
        JSON.parse(states.first.data)["status"].as_s.should eq("disabled")

        annotations = graph.objects(type: "semantic_annotation")
        JSON.parse(annotations.first.data)["status"].as_s.should eq("invalidated")
      end
    end
  end
end

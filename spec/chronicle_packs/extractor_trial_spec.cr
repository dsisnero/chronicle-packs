require "spec"
require "../spec_helper"

# ADR 0014 fork-trial-promote: the candidate extractor is trialled against
# the baseline over recorded evidence (drafts only, no materialization),
# then promoted with explicit approval citing the recorded evidence.

module TrialSupport
  extend self

  def with_semantic_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    yield store, graph, rt
  end

  def add_evidence(graph, text, id)
    graph.add_object("activity_evidence", JSON.build do |json|
      json.object do
        json.field "evidence_identity", "ev_#{id}"
        json.field "evidence_id", "evidence_#{id}"
        json.field "revision_id", "rev_#{id}"
        json.field "revision_number", 1
        json.field "source_surface_id", "chat/sess_1"
        json.field "source_category", "communication"
        json.field "connection_path", "export"
        json.field "source_ref", "msg_#{id}"
        json.field "importer_id", "i"
        json.field "importer_version", "1"
        json.field "status", "current"
        json.field "acquired_item_id", "acquired_item_1"
        json.field "acquired_content_id", "acquired_content_1"
        json.field "dedup_key", "d#{id}"
        json.field "content_hash", "0" * 64
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "replay_complete", false
        json.field "media_type", "text/plain"
        json.field "acquired_at_event_id", "evt_#{id}"
        json.field "normalized_content", text
        json.field "normalized_metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
  end
end

describe "extractor trial and promotion" do
  it "trials the candidate against the baseline over recorded content" do
    TrialSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      evidence_ids = ["Please send me the report.", "Could you share the update?", "Let me know the status."].map_with_index do |text, i|
        TrialSupport.add_evidence(graph, text, i + 1).id
      end

      result = se.run_extractor_trial_fn(
        graph, evidence_ids,
        candidate_ref: "semantic.request_rule@0.1.0",
        baseline_ref: "semantic.deterministic@0.1.0",
      )
      result["verdict"].as_s.should eq("candidate_richer")
      comparison = result["comparison"].as_h["relation_mention"].as_h
      comparison["candidate"].as_i.should be > 0
      comparison["baseline"].as_i.should eq(0)
      comparison["candidate_only"].as_i.should be > 0

      evidence_objs = graph.objects(type: "extractor_promotion_evidence")
      evidence_objs.size.should eq(1)
      trial_data = JSON.parse(evidence_objs.first.data)
      trial_data["candidate_extractor_id"].as_s.should eq("semantic.request_rule")
      trial_data["verdict"].as_s.should eq("candidate_richer")
    end
  end

  it "promotes the candidate extractor with explicit approval and routes its facets" do
    TrialSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      evidence_ids = ["Please send me the report.", "Could you share the update?", "Let me know the status."].map_with_index do |text, i|
        TrialSupport.add_evidence(graph, text, i + 1).id
      end
      trial = se.run_extractor_trial_fn(graph, evidence_ids, candidate_ref: "semantic.request_rule@0.1.0", baseline_ref: "semantic.deterministic@0.1.0")
      trial_id = trial["evidence_id"].as_s

      promoted = se.promote_llm_extractor_fn(graph, trial_id, approver: "owner")
      promoted["ok"].as_bool.should be_true
      promoted["extractor_ref"].as_s.should eq("semantic.request_rule@0.1.0")
      promoted["routed_facets"].as_a.map(&.as_s).should contain("relation_mention")

      states = graph.objects(type: "annotation_extractor_state")
      states.any? { |obj| JSON.parse(obj.data)["extractor_id"].as_s == "semantic.request_rule" && JSON.parse(obj.data)["status"].as_s == "promoted" }.should be_true
      profile_data = JSON.parse(graph.objects(type: "extraction_profile").last.data)
      profile_data["extractor_by_facet"].as_h["relation_mention"].as_s.should eq("semantic.request_rule@0.1.0")
    end
  end

  it "refuses promotion without an approver" do
    TrialSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      evidence_ids = ["Please send me the report.", "Could you share the update?", "Let me know the status."].map_with_index do |text, i|
        TrialSupport.add_evidence(graph, text, i + 1).id
      end
      trial = se.run_extractor_trial_fn(graph, evidence_ids, candidate_ref: "semantic.request_rule@0.1.0", baseline_ref: "semantic.deterministic@0.1.0")

      expect_raises(Exception) do
        se.promote_llm_extractor_fn(graph, trial["evidence_id"].as_s, approver: "")
      end
    end
  end
end

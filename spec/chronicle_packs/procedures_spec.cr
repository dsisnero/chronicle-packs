require "spec"
require "../spec_helper"

# Guarded proceduralization (ADR 0029 pilot): dynamic-to-deterministic
# extraction. A procedure_candidate is declarative graph state; evaluation
# runs the deterministic RequestRuleExtractorV1 against reference
# annotations; promotion is approver-gated. The port evaluates on the graph
# directly (deterministic, no mutation except the audit objects) instead of
# a runtime fork.

module ProceduresSupport
  extend self

  def with_semantic_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    yield store, graph, rt
  end

  # A communication evidence object whose normalized_metadata yields a stable
  # shape fingerprint. `requesting` puts a request cue in the content.
  def add_evidence(graph, text, id, requesting = true)
    content = requesting ? text : "the sky is blue and the grass is green"
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
        json.field "normalized_content", content
        json.field "normalized_metadata", JSON::Any.new({"direction" => JSON::Any.new("inbound"), "message_kind" => JSON::Any.new("chat"), "shape_version" => JSON::Any.new("v1")})
      end
    end)
  end

  # Run the request-rule extractor over *content* and record each draft as an
  # accepted reference annotation (LLM ref, active) — the ADR 0014 shape.
  def add_reference_annotation(graph, evidence_id, content, id)
    se = Chronicle::Packs::SemanticExtraction
    extractor = Chronicle::Packs::SemanticExtraction::Extractors::RequestRuleExtractorV1.new
    drafts = extractor.extract(content, {} of String => JSON::Any, ["relation_mention"])
    return if drafts.empty?

    draft = drafts.first
    annotation_obj = graph.add_object("semantic_annotation", JSON.build do |json|
      json.object do
        json.field "annotation_identity", "ann_#{id}"
        json.field "facet", "relation_mention"
        json.field "body", JSON::Any.new({"text" => JSON::Any.new(draft.exact), "subject" => JSON::Any.new("sender"), "predicate" => JSON::Any.new("requests"), "object" => JSON::Any.new(draft.exact)})
        json.field "evidence_id", evidence_id
        json.field "evidence_identity", "ev_#{evidence_id}"
        json.field "revision_id", "rev_#{evidence_id}"
        json.field "selector", JSON::Any.new({"kind" => JSON::Any.new("char_span"), "start" => JSON::Any.new(draft.start), "end" => JSON::Any.new(draft.end), "exact" => JSON::Any.new(draft.exact)})
        json.field "extractor_id", "semantic.llm"
        json.field "extractor_version", "0.1.0"
        json.field "config_hash", "0" * 64
        json.field "confidence", 0.85
        json.field "status", "active"
        json.field "run_id", "run_ref_#{id}"
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    graph.add_object("evaluation", JSON.build do |json|
      json.object do
        json.field "subject_type", "semantic_annotation"
        json.field "subject_id", annotation_obj.id
        json.field "judgment", "accepted"
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
  end
end

describe "guarded proceduralization" do
  it "RequestRuleExtractorV1 extracts explicit requests and registers" do
    se = Chronicle::Packs::SemanticExtraction
    extractor = Chronicle::Packs::SemanticExtraction::Extractors::RequestRuleExtractorV1.new
    extractor.extractor_id.should eq("semantic.request_rule")
    extractor.implemented_facets.should eq(["relation_mention"])
    drafts = extractor.extract("Please send me the report. The sky is blue.", {} of String => JSON::Any, ["relation_mention"])
    drafts.size.should eq(1)
    drafts.first.exact.should eq("Please send me the report.")
    drafts.first.metadata["cue"]?.try(&.as_s?).should eq("please")
    Chronicle::Packs::SemanticExtraction::Extractors.get_annotation_extractor("semantic.request_rule", "0.1.0").should be_a(Chronicle::Packs::SemanticExtraction::Extractors::RequestRuleExtractorV1)
  end

  it "shape_fingerprint is stable over the shape fields" do
    se = Chronicle::Packs::SemanticExtraction
    a = se.shape_fingerprint({"source_category" => JSON::Any.new("communication"), "normalized_metadata" => JSON::Any.new({"shape_version" => JSON::Any.new("v1")})})
    b = se.shape_fingerprint({"source_category" => JSON::Any.new("communication"), "normalized_metadata" => JSON::Any.new({"shape_version" => JSON::Any.new("v1")})})
    a.should eq(b)
    c = se.shape_fingerprint({"source_category" => JSON::Any.new("communication"), "normalized_metadata" => JSON::Any.new({"shape_version" => JSON::Any.new("v2")})})
    a.should_not eq(c)
  end

  it "synthesizes a guarded candidate from reviewed reference annotations" do
    ProceduresSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      witness_ids = [] of String
      (1..3).each do |i|
        ev = ProceduresSupport.add_evidence(graph, "Please send me the report.", i)
        ProceduresSupport.add_reference_annotation(graph, ev.id, "Please send me the report.", i)
        witness_ids << ev.id
      end
      held_ids = [] of String
      (4..5).each do |i|
        ev = ProceduresSupport.add_evidence(graph, "Could you share the update?", i)
        ProceduresSupport.add_reference_annotation(graph, ev.id, "Could you share the update?", i)
        held_ids << ev.id
      end
      counter_ids = [] of String
      (6..7).each do |i|
        counter_ids << ProceduresSupport.add_evidence(graph, "", i, requesting: false).id
      end

      result = se.synthesize_request_procedure_fn(graph, witness_evidence_ids: witness_ids, held_out_evidence_ids: held_ids, counterexample_evidence_ids: counter_ids, created_by: "operator")
      result["created"].as_bool.should be_true
      graph.objects(type: "procedure_guard").size.should eq(1)
      candidate_data = JSON.parse(graph.objects(type: "procedure_candidate").first.data)
      candidate_data["status"].as_s.should eq("candidate")
      candidate_data["semantic_objective"].as_s.should contain("requests")
    end
  end

  it "evaluates a candidate to pass and promotes it with an approver" do
    ProceduresSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      witness_ids = [] of String
      (1..3).each do |i|
        ev = ProceduresSupport.add_evidence(graph, "Please send me the report.", i)
        ProceduresSupport.add_reference_annotation(graph, ev.id, "Please send me the report.", i)
        witness_ids << ev.id
      end
      held_ids = [] of String
      (4..5).each do |i|
        ev = ProceduresSupport.add_evidence(graph, "Could you share the update?", i)
        ProceduresSupport.add_reference_annotation(graph, ev.id, "Could you share the update?", i)
        held_ids << ev.id
      end
      counter_ids = [] of String
      (6..7).each do |i|
        counter_ids << ProceduresSupport.add_evidence(graph, "", i, requesting: false).id
      end
      syn = se.synthesize_request_procedure_fn(graph, witness_evidence_ids: witness_ids, held_out_evidence_ids: held_ids, counterexample_evidence_ids: counter_ids, created_by: "operator")
      candidate_id = syn["candidate_id"].as_s

      evaluated = se.evaluate_request_procedure_fn(graph, candidate_id)
      evaluated["verdict"].as_s.should eq("pass")
      evaluation_id = evaluated["evaluation_id"].as_s

      promoted = se.promote_request_procedure_fn(graph, candidate_id, evaluation_id, approver: "owner")
      promoted["ok"].as_bool.should be_true
      candidate_data = JSON.parse(graph.objects(type: "procedure_candidate").first.data)
      candidate_data["status"].as_s.should eq("promoted")
      states = graph.objects(type: "annotation_extractor_state")
      states.any? { |obj| JSON.parse(obj.data)["extractor_id"].as_s == "semantic.request_rule" }.should be_true
    end
  end

  it "active_procedure_for and record_deoptimization handle guarded fallback" do
    ProceduresSupport.with_semantic_runtime do |_store, graph, _rt|
      se = Chronicle::Packs::SemanticExtraction
      witness_ids = [] of String
      (1..3).each do |i|
        ev = ProceduresSupport.add_evidence(graph, "Please send me the report.", i)
        ProceduresSupport.add_reference_annotation(graph, ev.id, "Please send me the report.", i)
        witness_ids << ev.id
      end
      held_ids = [] of String
      (4..5).each do |i|
        ev = ProceduresSupport.add_evidence(graph, "Could you share the update?", i)
        ProceduresSupport.add_reference_annotation(graph, ev.id, "Could you share the update?", i)
        held_ids << ev.id
      end
      counter_ids = [] of String
      (6..7).each do |i|
        counter_ids << ProceduresSupport.add_evidence(graph, "", i, requesting: false).id
      end
      syn = se.synthesize_request_procedure_fn(graph, witness_evidence_ids: witness_ids, held_out_evidence_ids: held_ids, counterexample_evidence_ids: counter_ids, created_by: "operator")
      candidate_id = syn["candidate_id"].as_s
      evaluated = se.evaluate_request_procedure_fn(graph, candidate_id)
      se.promote_request_procedure_fn(graph, candidate_id, evaluated["evaluation_id"].as_s, approver: "owner")

      active = se.active_procedure_for(graph, JSON.parse(graph.get_object(witness_ids.first).not_nil!.data).as_h, "relation_mention")
      active.should_not be_nil
      active.not_nil!["admitted"].as_bool.should be_true

      drift_evidence = ProceduresSupport.add_evidence(graph, "no cue here but same shape", 99, requesting: false)
      deopt = se.record_deoptimization(graph, graph, graph.get_object(candidate_id).not_nil!, graph.objects(type: "procedure_guard").first, graph.get_object(drift_evidence.id).not_nil!, "guard_abstained")
      deopt.should_not be_nil
      graph.objects(type: "procedure_deoptimization").size.should eq(1)
    end
  end
end

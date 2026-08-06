require "spec"
require "../spec_helper"

# Proceduralization tools: synthesize_request_procedure and
# promote_request_procedure — the guarded dynamic-to-deterministic lifecycle
# reachable through the gateway tool surface.

module ProcedureToolSupport
  extend self

  def with_semantic_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    yield store, graph, rt
  end

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

  def setup_evidence(graph)
    witness_ids = [] of String
    (1..3).each do |i|
      ev = add_evidence(graph, "Please send me the report.", i)
      add_reference_annotation(graph, ev.id, "Please send me the report.", i)
      witness_ids << ev.id
    end
    held_ids = [] of String
    (4..5).each do |i|
      ev = add_evidence(graph, "Could you share the update?", i)
      add_reference_annotation(graph, ev.id, "Could you share the update?", i)
      held_ids << ev.id
    end
    counter_ids = [] of String
    (6..7).each do |i|
      counter_ids << add_evidence(graph, "", i, requesting: false).id
    end
    {witness_ids, held_ids, counter_ids}
  end
end

describe "proceduralization tools" do
  it "synthesize_request_procedure_tool declares a guarded candidate" do
    ProcedureToolSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      witness_ids, held_ids, counter_ids = ProcedureToolSupport.setup_evidence(graph)
      Chronicle::Packs::SemanticExtraction.bound_graph = graph

      args = JSON.build do |json|
        json.object do
          json.field "witness_evidence_ids", JSON::Any.new(witness_ids.map { |id| JSON::Any.new(id) })
          json.field "held_out_evidence_ids", JSON::Any.new(held_ids.map { |id| JSON::Any.new(id) })
          json.field "counterexample_evidence_ids", JSON::Any.new(counter_ids.map { |id| JSON::Any.new(id) })
          json.field "created_by", "operator"
        end
      end
      result = JSON.parse(Chronicle::Packs::SemanticExtraction.synthesize_request_procedure_tool(args))
      result["ok"].as_bool.should be_true
      graph.objects(type: "procedure_candidate").size.should eq(1)
      graph.objects(type: "procedure_guard").size.should eq(1)
    ensure
      Chronicle::Packs::SemanticExtraction.bound_graph = nil
    end
  end

  it "promote_request_procedure_tool promotes only with its passing evaluation and an approver" do
    ProcedureToolSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      witness_ids, held_ids, counter_ids = ProcedureToolSupport.setup_evidence(graph)
      Chronicle::Packs::SemanticExtraction.bound_graph = graph
      se = Chronicle::Packs::SemanticExtraction

      synthesized = se.synthesize_request_procedure_fn(graph, witness_evidence_ids: witness_ids, held_out_evidence_ids: held_ids, counterexample_evidence_ids: counter_ids, created_by: "operator")
      candidate_id = synthesized["candidate_id"].as_s
      evaluated = se.evaluate_request_procedure_fn(graph, candidate_id)
      evaluation_id = evaluated["evaluation_id"].as_s

      args = JSON.build do |json|
        json.object do
          json.field "candidate_id", candidate_id
          json.field "evaluation_id", evaluation_id
          json.field "approver", "owner"
        end
      end
      result = JSON.parse(se.promote_request_procedure_tool(args))
      result["ok"].as_bool.should be_true
      candidate_data = JSON.parse(graph.objects(type: "procedure_candidate").first.data)
      candidate_data["status"].as_s.should eq("promoted")
    ensure
      Chronicle::Packs::SemanticExtraction.bound_graph = nil
    end
  end

  it "synthesize_request_procedure_tool fails loud on missing evidence" do
    ProcedureToolSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      Chronicle::Packs::SemanticExtraction.bound_graph = graph
      args = JSON.build do |json|
        json.object do
          json.field "witness_evidence_ids", JSON::Any.new(["missing_1", "missing_2", "missing_3"].map { |s| JSON::Any.new(s) })
          json.field "held_out_evidence_ids", JSON::Any.new(["missing_4", "missing_5"].map { |s| JSON::Any.new(s) })
          json.field "counterexample_evidence_ids", JSON::Any.new(["missing_6"].map { |s| JSON::Any.new(s) })
          json.field "created_by", "operator"
        end
      end
      expect_raises(Exception) do
        Chronicle::Packs::SemanticExtraction.synthesize_request_procedure_tool(args)
      end
    ensure
      Chronicle::Packs::SemanticExtraction.bound_graph = nil
    end
  end
end

require "spec"
require "../spec_helper"

# Eval Outcome pack (packs/eval_outcome): canonical terminal and maintenance
# outcomes with recency-aware artifact reliability. Ported from upstream
# packs/eval_outcome/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key. (The upstream fixture also loads memory_gateway;
# here the behaviors/tools are tested directly.)

module EvalOutcomeSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def eval_outcome_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "eval_outcome" / "manifest.toml"
  end

  def eval_outcome_settings(json : String) : Chronicle::Packs::EvalOutcome::EvalOutcomeSettings
    Chronicle::Packs::EvalOutcome::EvalOutcomeSettings.from_json(json)
  end

  def with_eval_runtime(custom_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if custom_settings
      rt.load_pack(Chronicle::Packs::EvalOutcome.pack, JSON.parse(custom_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::EvalOutcome.pack).should be_true
    end
    yield store, graph, rt
  end
end

include EvalOutcomeSpecSupport

describe Chronicle::Packs::EvalOutcome do
  describe "manifest-declared surface" do
    it "matches the upstream eval_outcome manifest" do
      pack = Chronicle::Packs::EvalOutcome.pack
      pack.name.should eq("eval_outcome")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq(["outcome_record", "artifact_reliability"])
      pack.relation_types.map(&.name).should eq(["records_evaluation", "updates_reliability"])
      pack.behaviors.map(&.name).should eq(["artifact_reliability_projector", "evaluation_outcome_capture"])
      pack.tools.map(&.name).should eq(
        ["record_explicit_verdict", "record_maintenance_outcome", "supersede_evaluation", "get_artifact_reliability"]
      )
      pack.settings_schema.should eq("EvalOutcomeSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(eval_outcome_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::EvalOutcome.pack)
    end
  end

  describe "record_explicit_verdict_fn" do
    it "records a rejection verdict, evaluation, and harmful reliability" do
      with_eval_runtime do |_store, graph, rt|
        result = Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
          graph, "reject", "verified harmful", "fixture-owner",
          artifact_id: "artifact_1", artifact_type: "memory_item"
        )
        result["created"].as_bool.should be_true

        evaluations = graph.objects(type: "evaluation")
        evaluations.size.should eq(1)
        eval_data = JSON.parse(evaluations.first.data)
        eval_data["judgment"].as_s.should eq("rejected")

        records = graph.objects(type: "outcome_record")
        records.size.should eq(1)
        record_data = JSON.parse(records.first.data)
        record_data["outcome_type"].as_s.should eq("hurt")
        record_data["artifact_id"].as_s.should eq("artifact_1")
        record_data["contribution_key"].as_s.should eq("terminal:#{evaluations.first.id}")

        rt.run_until_idle
        reliability = graph.objects(type: "artifact_reliability")
        reliability.size.should eq(1)
        rel_data = JSON.parse(reliability.first.data)
        rel_data["verdict"].as_s.should eq("harmful")
        rel_data["tallies"].as_h["hurt"].as_i.should eq(1)
      end
    end
  end

  describe "artifact_reliability_projector" do
    it "accumulates tallies and updates the verdict across outcomes" do
      with_eval_runtime do |_store, graph, rt|
        help = Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
          graph, "accept", "later verified helpful", "owner",
          artifact_id: "artifact_1", artifact_type: "memory_item"
        )
        rt.run_until_idle
        hurt = Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
          graph, "reject", "second opinion harmful", "owner",
          artifact_id: "artifact_1", artifact_type: "memory_item"
        )
        rt.run_until_idle

        reliability = graph.objects(type: "artifact_reliability")
        reliability.size.should eq(1)
        data = JSON.parse(reliability.first.data)
        data["tallies"].as_h["helped"].as_i.should eq(1)
        data["tallies"].as_h["hurt"].as_i.should eq(1)
        data["evidence_event_ids"].as_a.size.should eq(2)
      end
    end

    it "is idempotent per outcome event (no double tally)" do
      with_eval_runtime do |_store, graph, rt|
        help = Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
          graph, "accept", "helped", "owner", artifact_id: "a1", artifact_type: "memory_item"
        )
        rt.run_until_idle

        reliability = graph.objects(type: "artifact_reliability")
        data = JSON.parse(reliability.first.data)
        data["tallies"].as_h["helped"].as_i.should eq(1)
        data["evidence_event_ids"].as_a.size.should eq(1)
      end
    end
  end

  describe "record_maintenance_outcome_fn" do
    it "records a contradicted outcome idempotently and validates revision" do
      with_eval_runtime do |_store, graph, rt|
        expect_raises(Chronicle::Packs::PackError, /evidence_revision_id/) do
          Chronicle::Packs::EvalOutcome.record_maintenance_outcome_fn(graph, "outcome.contradicted", "a1", "memory_item", "revised", "owner")
        end

        first = Chronicle::Packs::EvalOutcome.record_maintenance_outcome_fn(
          graph, "outcome.contradicted", "a1", "memory_item", "revised", "owner",
          artifact_version: "v1", evidence_revision_id: "rev_2"
        )
        first["created"].as_bool.should be_true

        again = Chronicle::Packs::EvalOutcome.record_maintenance_outcome_fn(
          graph, "outcome.contradicted", "a1", "memory_item", "revised", "owner",
          artifact_version: "v1", evidence_revision_id: "rev_2"
        )
        again["created"].as_bool.should be_false
        graph.objects(type: "outcome_record").size.should eq(1)
      end
    end

    it "requires superseding_version for superseded" do
      with_eval_runtime do |_store, graph, _rt|
        expect_raises(Chronicle::Packs::PackError, /superseding_version/) do
          Chronicle::Packs::EvalOutcome.record_maintenance_outcome_fn(graph, "outcome.superseded", "a1", "memory_item", "replaced", "owner")
        end
      end
    end
  end

  describe "supersede_evaluation_fn" do
    it "corrects a terminal evaluation through replacement + superseded" do
      with_eval_runtime do |_store, graph, rt|
        original = Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
          graph, "accept", "accepted", "owner", artifact_id: "a1", artifact_type: "memory_item"
        )
        prior_evaluation_id = original["evaluation_id"].as_s

        superseded = Chronicle::Packs::EvalOutcome.supersede_evaluation_fn(
          graph, prior_evaluation_id, "reject", "corrected after review", "owner"
        )
        superseded["ok"].as_bool.should be_true

        evaluations = graph.objects(type: "evaluation")
        evaluations.size.should eq(2)
        rt.run_until_idle

        reliability = graph.objects(type: "artifact_reliability")
        data = JSON.parse(reliability.first.data)
        data["tallies"].as_h["superseded"].as_i.should eq(1)
      end
    end
  end

  describe "evaluation_outcome_capture" do
    it "captures a terminal outcome from a task evaluation" do
      with_eval_runtime do |_store, graph, rt|
        graph.add_object("evaluation", JSON.build do |json|
          json.object do
            json.field "subject_id", "task_1"
            json.field "subject_type", "task"
            json.field "judgment", "completed_successfully"
            json.field "rationale", "done"
            json.field "evaluator", "evaluation_capture"
            json.field "metadata", {"artifact_id" => JSON::Any.new("task_1"), "artifact_type" => JSON::Any.new("task")}
          end
        end)
        rt.run_until_idle

        records = graph.objects(type: "outcome_record")
        records.size.should eq(1)
        data = JSON.parse(records.first.data)
        data["outcome_type"].as_s.should eq("helped")
      end
    end
  end

  describe "get_reliability_fn" do
    it "returns the current reliability projection or nil" do
      with_eval_runtime do |_store, graph, rt|
        Chronicle::Packs::EvalOutcome.get_reliability_fn(graph, "a1").should be_nil
        Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(graph, "accept", "helped", "owner", artifact_id: "a1", artifact_type: "memory_item")
        rt.run_until_idle

        row = Chronicle::Packs::EvalOutcome.get_reliability_fn(graph, "a1")
        row.should_not be_nil
        row.not_nil!["object_id"].should_not be_nil
      end
    end
  end
end

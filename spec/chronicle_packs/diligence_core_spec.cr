require "spec"
require "../spec_helper"

# Diligence-Core Bridge (packs/bridges): maps Diligence pack objects to Core
# primitives so Diligence outputs appear alongside all other packs in the
# shared graph. Translated from upstream packs/bridges/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# The behaviors subscribe to object.created by type name (document/claim/
# memo/risk). Like the upstream fixture, this spec injects those objects
# directly into the graph without loading the real Diligence pack (which
# conflicts with Core on `derived_from`); the graph validator passes
# unregistered types through.

module DiligenceCoreSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def bridge_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "bridges" / "manifest.toml"
  end

  def with_bridge_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::Bridges.pack, {} of String => JSON::Any).should be_true
    Chronicle::Packs::Bridges::DiligenceCore.clear_bridge_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Bridges::DiligenceCore.clear_bridge_registry
  end

  def bridged(graph, type : String) : Array(Chronicle::GraphObject)
    graph.objects(type: type).select do |o|
      meta = JSON.parse(o.data)["metadata"]?.try(&.as_h)
      meta.try { |m| m["bridge"]? }.try(&.as_s?) == "diligence_core"
    end
  end
end

include DiligenceCoreSpecSupport

describe Chronicle::Packs::Bridges do
  describe "manifest-declared surface" do
    it "matches the upstream bridges manifest" do
      pack = Chronicle::Packs::Bridges.pack
      pack.name.should eq("diligence_core_bridge")
      pack.version.should eq("0.1.1")
      pack.object_types.map(&.name).should eq([] of String)
      pack.relation_types.map(&.name).should eq([] of String)
      pack.behaviors.map(&.name).should eq(
        ["document_to_source", "claim_to_observation", "memo_to_artifact", "risk_to_evaluation"]
      )
      pack.tools.map(&.name).should eq([] of String)
      pack.settings_schema.should eq("DiligenceCoreBridgeSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(bridge_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Bridges.pack)
    end
  end

  describe "fixture: document_claim_bridge" do
    it "turns a diligence document + claim into Core source + observation with derived_from/grounds" do
      with_bridge_runtime do |_store, graph, rt|
        doc = graph.add_object("document", {
          "title"        => JSON::Any.new("Northwind Robotics — Technical Due Diligence Report"),
          "url"          => JSON::Any.new("https://docs.example.com/northwind-dd.pdf"),
          "company_id"   => JSON::Any.new("company-001"),
          "summary"      => JSON::Any.new("Technical review of Northwind's robotics stack."),
          "published_at" => JSON::Any.new("2026-06-03"),
        }.to_json)
        rt.run_until_idle

        claim = graph.add_object("claim", {
          "text"               => JSON::Any.new("Northwind has 3 ex-Boston Dynamics engineers."),
          "confidence"         => JSON::Any.new(0.92),
          "company_id"         => JSON::Any.new("company-001"),
          "source_document_id" => JSON::Any.new(doc.id),
          "status"             => JSON::Any.new("verified"),
        }.to_json)
        rt.run_until_idle

        sources = bridged(graph, "source")
        observations = bridged(graph, "observation")
        sources.size.should eq(1)
        observations.size.should eq(1)

        src = JSON.parse(sources.first.data)
        src["kind"].as_s.should eq("document")
        src["content"].as_s.should eq("Technical review of Northwind's robotics stack.")
        src["url"].as_s.should eq("https://docs.example.com/northwind-dd.pdf")
        src_meta = src["metadata"].as_h
        src_meta["title"].as_s.should eq("Northwind Robotics — Technical Due Diligence Report")
        src_meta["company_id"].as_s.should eq("company-001")
        src_meta["published_at"].as_s.should eq("2026-06-03")
        src_meta["diligence_document_id"].as_s.should eq(doc.id)

        obs = JSON.parse(observations.first.data)
        obs["text"].as_s.should eq("Northwind has 3 ex-Boston Dynamics engineers.")
        obs["confidence"].as_f.should eq(0.92)
        obs["low_confidence"].as_bool.should be_false
        obs["category"].as_s.should eq("fact")
        obs["source_ids"].as_a.map(&.as_s).should eq([sources.first.id])
        obs_meta = obs["metadata"].as_h
        obs_meta["diligence_claim_id"].as_s.should eq(claim.id)
        obs_meta["diligence_claim_status"].as_s.should eq("verified")

        derived = graph.relations(type: "derived_from")
        derived.size.should eq(2)
        derived.any? { |r| r.from_id == sources.first.id && r.to_id == doc.id }.should be_true
        derived.any? { |r| r.from_id == observations.first.id && r.to_id == claim.id }.should be_true

        grounds = graph.relations(type: "grounds")
        grounds.any? { |r| r.from_id == sources.first.id && r.to_id == observations.first.id }.should be_true
      end
    end

    it "defaults missing fields (title/url/summary/confidence) like upstream" do
      with_bridge_runtime do |_store, graph, rt|
        doc = graph.add_object("document", {
          "title" => JSON::Any.new(""),
        }.to_json)
        rt.run_until_idle

        sources = bridged(graph, "source")
        sources.size.should eq(1)
        src = JSON.parse(sources.first.data)
        src["kind"].as_s.should eq("document")
        src["content"].as_s.should eq("")
        src["url"]?.try(&.as_s?).should be_nil
        src["metadata"].as_h["title"].as_s.should eq("Untitled Document")
      end
    end
  end

  describe "fixture: memo_risk_bridge" do
    it "turns a diligence memo + risk into Core artifact + evaluation with derived_from" do
      with_bridge_runtime do |_store, graph, rt|
        risk = graph.add_object("risk", {
          "title"             => JSON::Any.new("Single customer concentration"),
          "description"       => JSON::Any.new("One customer accounts for 78% of ARR."),
          "severity"          => JSON::Any.new("high"),
          "company_id"        => JSON::Any.new("company-002"),
          "related_claim_ids" => JSON::Any.new([] of JSON::Any),
        }.to_json)
        rt.run_until_idle

        memo = graph.add_object("memo", {
          "company_id"                 => JSON::Any.new("company-002"),
          "summary"                    => JSON::Any.new("TensorWave has compelling technology."),
          "thesis_questions_addressed" => JSON::Any.new([
            JSON::Any.new("Is the technology differentiated? Yes."),
          ]),
          "key_claims" => JSON::Any.new([
            JSON::Any.new("ARR is $2.4M, growing 18% MoM"),
          ]),
          "open_contradictions" => JSON::Any.new([
            JSON::Any.new("Customer LOI vs actual signed contract unclear"),
          ]),
          "risks" => JSON::Any.new([
            JSON::Any.new("Single customer concentration (78% ARR)"),
          ]),
        }.to_json)
        rt.run_until_idle

        artifacts = bridged(graph, "artifact")
        evaluations = bridged(graph, "evaluation")
        artifacts.size.should eq(1)
        evaluations.size.should eq(1)

        art = JSON.parse(artifacts.first.data)
        art["kind"].as_s.should eq("memo")
        art["title"].as_s.should eq("Diligence Memo: company-002")
        art["format"].as_s.should eq("markdown")
        art["status"].as_s.should eq("draft")
        art["metadata"].as_h["diligence_memo_id"].as_s.should eq(memo.id)
        content = art["content"].as_s
        content.should contain("# Diligence Memo: company-002")
        content.should contain("## Summary\nTensorWave has compelling technology.")
        content.should contain("## Key Claims\n- ARR is $2.4M, growing 18% MoM")
        content.should contain("## Thesis Questions Addressed\n- Is the technology differentiated? Yes.")
        content.should contain("## Open Contradictions\n- Customer LOI vs actual signed contract unclear")
        content.should contain("## Risks\n- Single customer concentration (78% ARR)")

        evl = JSON.parse(evaluations.first.data)
        evl["subject_id"].as_s.should eq(risk.id)
        evl["subject_type"].as_s.should eq("risk")
        evl["judgment"].as_s.should eq("high")
        evl["rationale"].as_s.should eq("Single customer concentration: One customer accounts for 78% of ARR.")
        evl["evaluator"].as_s.should eq("diligence_core_bridge")
        evl["metadata"].as_h["diligence_risk_id"].as_s.should eq(risk.id)

        derived = graph.relations(type: "derived_from")
        derived.size.should eq(2)
        derived.any? { |r| r.from_id == artifacts.first.id && r.to_id == memo.id }.should be_true
        derived.any? { |r| r.from_id == evaluations.first.id && r.to_id == risk.id }.should be_true
      end
    end

    it "defaults risk title/severity and memo company_id like upstream" do
      with_bridge_runtime do |_store, graph, rt|
        risk = graph.add_object("risk", {
          "description" => JSON::Any.new("Something is off."),
        }.to_json)
        rt.run_until_idle

        graph.add_object("memo", ({} of String => JSON::Any).to_json)
        rt.run_until_idle

        evaluations = bridged(graph, "evaluation")
        evaluations.size.should eq(1)
        evl = JSON.parse(evaluations.first.data)
        evl["judgment"].as_s.should eq("medium")
        evl["rationale"].as_s.should eq("Unspecified Risk: Something is off.")

        artifacts = bridged(graph, "artifact")
        artifacts.size.should eq(1)
        JSON.parse(artifacts.first.data)["title"].as_s.should eq("Diligence Memo: unknown")
      end
    end
  end

  describe "dedup" do
    it "is idempotent per diligence object id via the bridge registry" do
      with_bridge_runtime do |_store, graph, rt|
        payload = {
          "id"   => JSON::Any.new("document#1"),
          "type" => JSON::Any.new("document"),
          "data" => JSON::Any.new({
            "title" => JSON::Any.new("Report"),
            "url"   => JSON::Any.new("https://example.com/report"),
          }),
        }.to_json
        # Emit the same object.created payload twice (event replay) — the
        # bridge must bridge only once per diligence object id.
        2.times do |i|
          graph.emit(Chronicle::Event.new(
            schema_version: 1_u16, sequence: (i + 1).to_u64, id: "obj_created_#{i + 1}",
            type: "object.created", actor: "spec", caused_by: nil, payload: payload
          ))
          rt.run_until_idle
        end

        bridged(graph, "source").size.should eq(1)
        derived = graph.relations(type: "derived_from")
        derived.size.should eq(1)
      end
    end
  end
end

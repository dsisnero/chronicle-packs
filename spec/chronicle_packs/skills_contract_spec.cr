require "spec"
require "../spec_helper"

# P4 acceptance contract for governed learned skill artifacts (upstream
# tests/test_skills.py). Skills author immutably, invoke idempotently under
# retries, promote/demote through recorded evidence with explainable
# history, select exact versions, and arrive from normalizer candidates as
# provenance-backed proposals.

module SkillsContractSpecSupport
  extend self

  def with_skills_contract_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::Skills.pack).should be_true
    yield store, graph, rt
  end

  def author(graph : Chronicle::GraphProjection, version : String = "0.1.0")
    Chronicle::Packs::Skills.author_skill_fn(
      graph, "repo_audit_summary", version,
      "Repository audit summary definition #{version}.",
      ["repo_audit_report.exists"],
      ["repo.read"],
      ["missing source evidence"],
      ["evidence:#{version}"],
    )["skill"].as_h
  end

  # The skill object's own data hash (name/version live under .data).
  def skill_data(skill : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    skill["data"].as_h
  end

  def proof(graph : Chronicle::GraphProjection, skill_id : String, version : String)
    Chronicle::Packs::Skills.record_promotion_evidence_fn(
      graph, skill_id, "verification",
      ["verification:#{version}"],
      "acceptance fixture passed",
      "owner:test",
    )["evidence"].as_h
  end

  def list_eligible_skills_fn(graph : Chronicle::GraphProjection)
    Chronicle::Packs::Skills.list_eligible_skills_fn(graph)
  end
end

include SkillsContractSpecSupport

describe "skills P4 acceptance contract" do
  it "executes and evaluates at most once per usage_id under retries" do
    with_skills_contract_runtime do |_store, graph, _rt|
      skill = author(graph)
      first = Chronicle::Packs::Skills.invoke_skill_fn(
        graph, skill_data(skill)["name"].as_s, skill_data(skill)["version"].as_s, "usage-1", "trial:1", actor: "agent:test")
      retry_result = Chronicle::Packs::Skills.invoke_skill_fn(
        graph, skill_data(skill)["name"].as_s, skill_data(skill)["version"].as_s, "usage-1", "trial:1", actor: "agent:test")
      first["created"].as_bool.should be_true
      retry_result["created"].as_bool.should be_false
      graph.objects(type: "skill_usage").size.should eq(1)
      graph.events.count { |event| event.type == "skill.used" }.should eq(1)

      usage_id = first["usage"].as_h["id"].as_s
      evaluation = graph.add_object("evaluation", JSON.build do |json|
        json.object do
          json.field "subject_id", usage_id
          json.field "subject_type", "skill_usage"
          json.field "judgment", "completed_successfully"
          json.field "metadata", JSON::Any.new({"usage_id" => JSON::Any.new("usage-1")})
        end
      end)
      Chronicle::Packs::Skills.link_skill_evaluation_fn(graph, "usage-1", evaluation.id)["created"].as_bool.should be_true
      Chronicle::Packs::Skills.link_skill_evaluation_fn(graph, "usage-1", evaluation.id)["created"].as_bool.should be_false

      second = graph.add_object("evaluation", JSON.build do |json|
        json.object do
          json.field "subject_id", usage_id
          json.field "subject_type", "skill_usage"
          json.field "judgment", "needs_revision"
          json.field "metadata", JSON::Any.new({"usage_id" => JSON::Any.new("usage-1")})
        end
      end)
      expect_raises(Chronicle::Packs::PackError, /already been evaluated/i) do
        Chronicle::Packs::Skills.link_skill_evaluation_fn(graph, "usage-1", second.id)
      end
      graph.events.count { |event| event.type == "skill.evaluated" }.should eq(1)
    end
  end

  it "promotion requires recorded evidence and is explainable" do
    with_skills_contract_runtime do |_store, graph, _rt|
      skill = author(graph)
      expect_raises(Chronicle::Packs::PackError, /recorded evidence/i) do
        Chronicle::Packs::Skills.promote_skill_fn(graph, skill["id"].as_s, "missing", "sounds useful")
      end

      proof_record = proof(graph, skill["id"].as_s, skill_data(skill)["version"].as_s)
      result = Chronicle::Packs::Skills.promote_skill_fn(
        graph, skill["id"].as_s, proof_record["data"].as_h["evidence_id"].as_s,
        "verified acceptance behavior", "owner:test",
      )
      promoted = result["skill"].as_h
      promoted["data"].as_h["status"].as_s.should eq("promoted")
      history = promoted["data"].as_h["promotion_history"].as_a
      history.last.as_h["evidence_id"].as_s.should eq(proof_record["data"].as_h["evidence_id"].as_s)
      history.last.as_h["rationale"].as_s.should eq("verified acceptance behavior")
      promoted_event = graph.events.select { |event| event.type == "skill.promoted" }.last
      JSON.parse(promoted_event.payload)["skill_version"].as_s.should eq("0.1.0")
    end
  end

  it "demotion removes eligibility, preserves history, and is reversible" do
    with_skills_contract_runtime do |_store, graph, _rt|
      skill = author(graph)
      proof_record = proof(graph, skill["id"].as_s, skill_data(skill)["version"].as_s)
      Chronicle::Packs::Skills.promote_skill_fn(graph, skill["id"].as_s, proof_record["data"].as_h["evidence_id"].as_s, "verified")
      Chronicle::Packs::Skills.invoke_skill_fn(
        graph, skill_data(skill)["name"].as_s, skill_data(skill)["version"].as_s, "usage-history", "run:history",
        execution_kind: "real", actor: "agent:test",
      )
      list_eligible_skills_fn(graph).any? { |row| row["object_id"].as_s == skill["id"].as_s }.should be_true

      Chronicle::Packs::Skills.demote_skill_fn(graph, skill["id"].as_s, "harmful verified outcome")
      list_eligible_skills_fn(graph).any? { |row| row["object_id"].as_s == skill["id"].as_s }.should be_false
      expect_raises(Chronicle::Packs::PackError, /not eligible/i) do
        Chronicle::Packs::Skills.invoke_skill_fn(graph, skill_data(skill)["name"].as_s, skill_data(skill)["version"].as_s, "usage-blocked", "run:blocked")
      end
      graph.objects(type: "skill_usage").size.should eq(1)

      restored = Chronicle::Packs::Skills.promote_skill_fn(graph, skill["id"].as_s, proof_record["data"].as_h["evidence_id"].as_s, "re-verified")
      restored["skill"].as_h["data"].as_h["status"].as_s.should eq("promoted")
      restored["skill"].as_h["data"].as_h["promotion_history"].as_a.size.should eq(2)
    end
  end

  it "version selection is exact and material changes require a new version" do
    with_skills_contract_runtime do |_store, graph, _rt|
      v1 = author(graph, "0.1.0")
      v2 = author(graph, "0.2.0")
      proof_record = proof(graph, v1["id"].as_s, "0.1.0")
      Chronicle::Packs::Skills.promote_skill_fn(graph, v1["id"].as_s, proof_record["data"].as_h["evidence_id"].as_s, "v1 verified")

      usage = Chronicle::Packs::Skills.invoke_skill_fn(
        graph, skill_data(v1)["name"].as_s, "0.1.0", "usage-v1-after-v2", "run:v1",
        execution_kind: "real", actor: "agent:test",
      )["usage"].as_h
      usage["data"].as_h["skill_version_id"].as_s.should eq(v1["id"].as_s)
      usage["data"].as_h["skill_version"].as_s.should eq("0.1.0")
      usage["data"].as_h["skill_version_id"].as_s.should_not eq(v2["id"].as_s)

      expect_raises(Chronicle::Packs::PackError, /materially new semantic version/i) do
        Chronicle::Packs::Skills.author_skill_fn(
          graph, skill_data(v1)["name"].as_s, "0.1.0",
          "Changed definition under the same version.",
          ["repo_audit_report.exists"], ["repo.read"], [] of String, ["evidence:changed"],
        )
      end
    end
  end

  it "a normalizer skill candidate becomes a provenance-backed proposal" do
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    rt.load_pack(Chronicle::Packs::Skills.pack).should be_true
    begin
      candidate = graph.add_object("skill_candidate", JSON.build do |json|
        json.object do
          json.field "candidate_identity", "candidate-skill-1"
          json.field "text", "Summarize repo audits."
          json.field "confidence", 0.8
          json.field "evidence_id", "activity_evidence#1"
          json.field "evidence_identity", "evidence-1"
          json.field "revision_id", "revision-1"
          json.field "extraction_record_id", "extraction_record#1"
          json.field "extractor_id", "activity.structure"
          json.field "extractor_version", "0.1.0"
          json.field "extraction_config_id", "default"
          json.field "status", "candidate"
          json.field "name", "repo_audit_summary"
          json.field "description", "Summarize repo audits."
          json.field "metadata", JSON::Any.new({} of String => JSON::Any)
        end
      end)
      rt.run_until_idle

      skills = graph.objects(type: "skill")
      skills.size.should eq(1)
      JSON.parse(skills.first.data)["source_candidate_id"].as_s.should eq(candidate.id)
      JSON.parse(skills.first.data)["source_evidence_refs"].as_a.map(&.as_s).should contain("activity_evidence#1")
      proposed = graph.events.select { |event| event.type == "skill.proposed" }
      proposed.size.should eq(1)
      JSON.parse(proposed.first.payload)["source_candidate_id"].as_s.should eq(candidate.id)
    end
  end
end

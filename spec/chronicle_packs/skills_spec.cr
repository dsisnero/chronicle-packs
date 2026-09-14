require "spec"
require "../spec_helper"

# Skills pack (packs/skills): versioned, provenance-backed learned skills
# with lifecycle (author/invoke/evidence/promote/demote/disable). Ported
# from upstream packs/skills/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no API key.

module SkillsSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def skills_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "skills" / "manifest.toml"
  end

  def skills_settings(json : String) : Chronicle::Packs::Skills::SkillsSettings
    Chronicle::Packs::Skills::SkillsSettings.from_json(json)
  end

  def with_skills_runtime(custom_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if custom_settings
      rt.load_pack(Chronicle::Packs::Skills.pack, JSON.parse(custom_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::Skills.pack).should be_true
    end
    yield store, graph, rt
  end

  def with_durable_skills_runtime(&)
    path = File.tempname("skills_replay", ".sqlite")
    store = Chronicle::SQLiteEventStore.new(path, run_id: "skills_parent")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    log_agent = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: log_agent, graph: graph, run_id: "skills_parent")
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::Skills.pack).should be_true
    yield graph, rt
  ensure
    store.close if store
    File.delete(path.not_nil!) if path && File.exists?(path.not_nil!)
  end

  def emit(graph : Chronicle::GraphProjection, type : String, payload : String, seq : UInt64)
    graph.emit(Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{type.gsub('.', '_')}_#{seq}",
      type: type, actor: "spec", caused_by: nil, payload: payload
    ))
  end

  def author_skill(graph : Chronicle::GraphProjection, name : String = "summarize", version : String = "0.1.0")
    Chronicle::Packs::Skills.author_skill_fn(
      graph, name, version, "Summarize a thread", ["summarize"], ["read"], [] of String,
      ["ev_1"], nil, "owner", false, {} of String => JSON::Any
    )
  end
end

include SkillsSpecSupport

describe Chronicle::Packs::Skills do
  describe "manifest-declared surface" do
    it "matches the upstream skills manifest" do
      pack = Chronicle::Packs::Skills.pack
      pack.name.should eq("skills")
      pack.version.should eq("0.2.0")
      pack.object_types.map(&.name).should eq(
        ["skill", "skill_usage", "skill_promotion_evidence", "skill_evaluation_link"]
      )
      pack.relation_types.map(&.name).should eq(
        ["usage_of", "promotion_for", "evaluation_of_usage", "links_evaluation"]
      )
      pack.behaviors.map(&.name).should eq(
        ["skill_candidate_author", "skill_evaluation_linker", "skill_reliability_eligibility", "skill_outcome_summary"]
      )
      pack.tools.map(&.name).should eq(
        ["author_skill", "invoke_skill", "record_skill_promotion_evidence", "promote_skill", "demote_skill", "disable_skill"]
      )
      pack.settings_schema.should eq("SkillsSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(skills_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Skills.pack)
    end
  end

  describe "author_skill_fn" do
    it "authors an immutable skill version with provenance" do
      with_skills_runtime do |_store, graph, _rt|
        result = author_skill(graph)
        result["created"].as_bool.should be_true
        skill = graph.objects(type: "skill").first
        data = JSON.parse(skill.data)
        data["status"].as_s.should eq("candidate")
        data["definition_hash"].as_s.should match(/^[0-9a-f]{64}$/)
        data["source_evidence_refs"].as_a.map(&.as_s).should eq(["ev_1"])
      end
    end

    it "is idempotent for the same definition" do
      with_skills_runtime do |_store, graph, _rt|
        first = author_skill(graph)
        second = author_skill(graph)
        second["created"].as_bool.should be_false
        graph.objects(type: "skill").size.should eq(1)
      end
    end

    it "rejects a different definition for the same name/version" do
      with_skills_runtime do |_store, graph, _rt|
        author_skill(graph)
        expect_raises(Chronicle::Packs::PackError, /different definition/) do
          Chronicle::Packs::Skills.author_skill_fn(
            graph, "summarize", "0.1.0", "Different description", ["summarize"], ["read"], [] of String, ["ev_1"], nil, "owner", false, {} of String => JSON::Any
          )
        end
      end
    end

    it "requires source evidence provenance" do
      with_skills_runtime do |_store, graph, _rt|
        expect_raises(Chronicle::Packs::PackError, /source evidence provenance/) do
          Chronicle::Packs::Skills.author_skill_fn(graph, "summarize", "0.1.0", "", [] of String, [] of String, [] of String, [] of String)
        end
      end
    end
  end

  describe "invoke_skill_fn" do
    it "invokes a candidate version once in a trial" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        result = Chronicle::Packs::Skills.invoke_skill_fn(graph, "summarize", "0.1.0", "u1", "ref1", "trial", "agent", {"frame_id" => JSON::Any.new("f1")})
        result["created"].as_bool.should be_true
        usage = graph.objects(type: "skill_usage").first
        data = JSON.parse(usage.data)
        data["usage_id"].as_s.should eq("u1")
        data["execution_kind"].as_s.should eq("trial")

        # usage_of relation
        graph.relations(source: usage.id, type: "usage_of").size.should eq(1)
      end
    end

    it "is idempotent for the same usage_id" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        Chronicle::Packs::Skills.invoke_skill_fn(graph, "summarize", "0.1.0", "u1", "ref1", "trial")
        again = Chronicle::Packs::Skills.invoke_skill_fn(graph, "summarize", "0.1.0", "u1", "ref1", "trial")
        again["created"].as_bool.should be_false
        graph.objects(type: "skill_usage").size.should eq(1)
      end
    end

    it "rejects real invocation of a non-promoted version" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        expect_raises(Chronicle::Packs::PackError, /requires a promoted skill version/) do
          Chronicle::Packs::Skills.invoke_skill_fn(graph, "summarize", "0.1.0", "u1", "ref1", "real")
        end
      end
    end
  end

  describe "promotion lifecycle" do
    it "records evidence and promotes a supported skill" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        skill = graph.objects(type: "skill").first

        evidence = Chronicle::Packs::Skills.record_promotion_evidence_fn(graph, skill.id, "trial", ["trial_1"], "two trials passed", "owner")
        evidence["created"].as_bool.should be_true
        evidence_id = evidence["evidence"].as_h["data"].as_h["evidence_id"].as_s

        promoted = Chronicle::Packs::Skills.promote_skill_fn(graph, skill.id, evidence_id, "passing trials")
        promoted["changed"].as_bool.should be_true
        skill_data = JSON.parse(graph.get_object(skill.id).not_nil!.data)
        skill_data["status"].as_s.should eq("promoted")
        skill_data["promotion_history"].as_a.size.should eq(1)
      end
    end

    it "demotes and disables without erasing history" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        skill = graph.objects(type: "skill").first

        demoted = Chronicle::Packs::Skills.demote_skill_fn(graph, skill.id, "no longer useful", "owner")
        demoted["changed"].as_bool.should be_true
        JSON.parse(graph.get_object(skill.id).not_nil!.data)["status"].as_s.should eq("demoted")

        disabled = Chronicle::Packs::Skills.disable_skill_fn(graph, skill.id, "suspended", "owner")
        disabled["changed"].as_bool.should be_true
        JSON.parse(graph.get_object(skill.id).not_nil!.data)["status"].as_s.should eq("disabled")
      end
    end
  end

  describe "skill_outcome_summary" do
    it "tallies canonical outcomes on the skill" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        skill = graph.objects(type: "skill").first

        emit(graph, "outcome.helped", %({"artifact_type":"skill_version","artifact_id":"#{skill.id}"}), 1_u64)
        emit(graph, "outcome.hurt", %({"artifact_type":"skill_version","artifact_id":"#{skill.id}"}), 2_u64)
        rt.run_until_idle

        summary = JSON.parse(graph.get_object(skill.id).not_nil!.data)["outcome_summary"].as_h
        summary["helped"].as_i.should eq(1)
        summary["hurt"].as_i.should eq(1)
      end
    end
  end

  describe "skill_reliability_eligibility" do
    it "demotes on a harmful reliability verdict" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        skill = graph.objects(type: "skill").first

        emit(graph, "reliability.changed", %({"artifact_type":"skill_version","artifact_id":"#{skill.id}","verdict":"harmful","outcome_event_id":"oe_1"}), 1_u64)
        rt.run_until_idle

        data = JSON.parse(graph.get_object(skill.id).not_nil!.data)
        data["status"].as_s.should eq("demoted")
        data["demotion_reason"].as_s.should eq("reliability became harmful")
      end
    end

    it "re-promotes a reliability-demoted skill on a supported verdict" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        skill = graph.objects(type: "skill").first

        emit(graph, "reliability.changed", %({"artifact_type":"skill_version","artifact_id":"#{skill.id}","verdict":"harmful","outcome_event_id":"oe_1"}), 1_u64)
        rt.run_until_idle
        emit(graph, "reliability.changed", %({"artifact_type":"skill_version","artifact_id":"#{skill.id}","verdict":"supported","outcome_event_id":"oe_2"}), 2_u64)
        rt.run_until_idle

        data = JSON.parse(graph.get_object(skill.id).not_nil!.data)
        data["status"].as_s.should eq("promoted")
        data["promotion_history"].as_a.size.should eq(1)
      end
    end
  end

  describe "skill_evaluation_linker" do
    it "links a Core evaluation carrying usage provenance" do
      with_skills_runtime do |_store, graph, rt|
        author_skill(graph)
        rt.run_until_idle
        Chronicle::Packs::Skills.invoke_skill_fn(graph, "summarize", "0.1.0", "u1", "ref1", "trial")
        usage_id = "u1"

        graph.add_object("evaluation", JSON.build do |json|
          json.object do
            json.field "subject_id", "s1"
            json.field "subject_type", "skill_usage"
            json.field "judgment", "completed_successfully"
            json.field "metadata", {"usage_id" => JSON::Any.new(usage_id)}
          end
        end)
        rt.run_until_idle

        links = graph.objects(type: "skill_evaluation_link")
        links.size.should eq(1)
        data = JSON.parse(links.first.data)
        data["usage_id"].as_s.should eq(usage_id)
        graph.relations(type: "links_evaluation").size.should eq(1)
      end
    end
  end

  describe "verify_skill_replay_fn" do
    it "earns replay.verified once per promoted version from a durable fork trial" do
      with_durable_skills_runtime do |graph, rt|
        author_skill(graph, "weekly_briefing", "1.0.0")
        skill = graph.objects(type: "skill").first
        Chronicle::Packs::Skills.invoke_skill_fn(graph, "weekly_briefing", "1.0.0", "usage_p6_1", "run_p6_1", "trial")
        evidence = Chronicle::Packs::Skills.record_promotion_evidence_fn(graph, skill.id, "trial", ["usage_p6_1"], "trial passed", "owner")
        evidence_id = evidence["evidence"].as_h["data"].as_h["evidence_id"].as_s
        Chronicle::Packs::Skills.promote_skill_fn(graph, skill.id, evidence_id, "trial passed", "owner")

        verified = Chronicle::Packs::Skills.verify_skill_replay_fn(graph, rt, skill.id)
        verified["created"].as_bool.should be_true
        replay = graph.events.find { |event| event.type == "replay.verified" }.not_nil!
        data = JSON.parse(replay.payload)
        data["subject_id"].as_s.should eq(JSON.parse(skill.data)["skill_id"].as_s)
        data["subject_version"].as_s.should eq("1.0.0")
        data["method"].as_s.should eq("fork_trial_rerun")
        graph.objects(type: "skill_usage").map { |usage| JSON.parse(usage.data)["usage_id"].as_s }.should_not contain("replay::usage_p6_1")

        again = Chronicle::Packs::Skills.verify_skill_replay_fn(graph, rt, skill.id)
        again["created"].as_bool.should be_false
        again["event_id"].as_s.should eq(verified["event_id"].as_s)
      end
    end

    it "fails closed for unpromoted versions and replay-incomplete lineage" do
      with_durable_skills_runtime do |graph, rt|
        author_skill(graph, "unpromoted", "1.0.0")
        skill = graph.objects(type: "skill").first
        expect_raises(Chronicle::Packs::PackError, /promoted/) do
          Chronicle::Packs::Skills.verify_skill_replay_fn(graph, rt, skill.id)
        end

        source = graph.add_object("source", {"kind" => JSON::Any.new("export"), "content" => JSON::Any.new("evidence"), "metadata" => JSON::Any.new({"replay_complete" => JSON::Any.new(false), "acquisition" => JSON::Any.new({"replay_mode" => JSON::Any.new("reference_only")})})}.to_json)
        Chronicle::Packs::Skills.author_skill_fn(graph, "reference_only", "1.0.0", source_evidence_refs: [source.id])
        ref_skill = graph.objects(type: "skill").last
        Chronicle::Packs::Skills.invoke_skill_fn(graph, "reference_only", "1.0.0", "usage_ref_1", "run_ref_1", "trial")
        evidence = Chronicle::Packs::Skills.record_promotion_evidence_fn(graph, ref_skill.id, "trial", ["usage_ref_1"], "trial passed", "owner")
        evidence_id = evidence["evidence"].as_h["data"].as_h["evidence_id"].as_s
        Chronicle::Packs::Skills.promote_skill_fn(graph, ref_skill.id, evidence_id, "trial passed", "owner")
        expect_raises(Chronicle::Packs::Skills::SkillReplayIncompleteError, /ADR 0015/) do
          Chronicle::Packs::Skills.verify_skill_replay_fn(graph, rt, ref_skill.id)
        end
      end
    end
  end

  describe "skill_candidate_author" do
    it "authors a skill from a normalizer candidate" do
      with_skills_runtime do |_store, graph, rt|
        graph.add_object("skill_candidate", JSON.build do |json|
          json.object do
            json.field "name", "extract decisions"
            json.field "status", "candidate"
            json.field "evidence_id", "ev_cand_1"
            json.field "metadata", {"skill_version" => JSON::Any.new("0.1.0")}
          end
        end)
        rt.run_until_idle

        skills = graph.objects(type: "skill")
        skills.size.should eq(1)
        data = JSON.parse(skills.first.data)
        data["name"].as_s.should eq("extract decisions")
        data["source_evidence_refs"].as_a.map(&.as_s).should contain("ev_cand_1")
      end
    end
  end
end

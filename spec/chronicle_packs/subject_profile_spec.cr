require "spec"
require "../spec_helper"

# Subject Profile Pack (packs/subject_profile): evidence-backed, explicitly
# reviewed subject facts with contradiction and supersession lifecycles.
# Translated from upstream packs/subject_profile/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# The behavior consumes activity_normalizer's `profile_candidate` and
# `activity_evidence` objects. This spec creates those objects directly
# (the graph validator passes unregistered types through), mirroring how
# the upstream fixtures would drive them.

module SubjectProfileSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def subject_profile_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "subject_profile" / "manifest.toml"
  end

  def with_subject_profile_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::SubjectProfile::SubjectProfileSettings.new
    rt.load_pack(Chronicle::Packs::SubjectProfile.pack, JSON.parse(settings.to_json).as_h).should be_true
    yield store, graph, rt
  end

  # An activity_evidence carrying owner-scoped normalized metadata (or nil
  # scope when scope is nil, for the fails-closed path).
  def add_evidence(graph, source_surface_id : String = "surf_owner_1", scope : String? = "owner_profile")
    meta = scope ? {"subject_scope" => JSON::Any.new(scope)} : {} of String => JSON::Any
    graph.add_object("activity_evidence", {
      "evidence_identity"    => JSON::Any.new("evidence_#{source_surface_id}"),
      "revision_id"          => JSON::Any.new("rev_1"),
      "revision_number"      => JSON::Any.new(1),
      "acquired_item_id"     => JSON::Any.new("item_1"),
      "acquired_content_id"  => JSON::Any.new("content_1"),
      "source_surface_id"    => JSON::Any.new(source_surface_id),
      "dedup_key"            => JSON::Any.new("d1"),
      "source_ref"           => JSON::Any.new("s1"),
      "content_hash"         => JSON::Any.new("abc"),
      "replay_mode"          => JSON::Any.new("full"),
      "replay_payload_ref"   => JSON::Any.new("r"),
      "replay_payload_hash"  => JSON::Any.new("h"),
      "replay_complete"      => JSON::Any.new(true),
      "media_type"           => JSON::Any.new("text/plain"),
      "acquired_at_event_id" => JSON::Any.new("evt_1"),
      "normalized_content"   => JSON::Any.new(""),
      "source_category"      => JSON::Any.new("manual"),
      "connection_path"      => JSON::Any.new("direct"),
      "importer_id"          => JSON::Any.new("i"),
      "importer_version"     => JSON::Any.new("1"),
      "normalized_metadata"  => JSON::Any.new(meta),
    }.to_json)
  end

  # A profile_candidate extracted from the given evidence.
  def add_candidate(graph, evidence, value : String, attribute : String = "profile_statement", text : String? = nil, confidence : Float64 = 0.8)
    graph.add_object("profile_candidate", {
      "candidate_identity"   => JSON::Any.new("cand_#{value}"),
      "text"                 => JSON::Any.new(text || value),
      "confidence"           => JSON::Any.new(confidence),
      "evidence_id"          => JSON::Any.new(evidence.id),
      "evidence_identity"    => JSON::Any.new("evidence_#{JSON.parse(evidence.data)["source_surface_id"].as_s}"),
      "revision_id"          => JSON::Any.new("rev_1"),
      "extractor_id"         => JSON::Any.new("ext_1"),
      "extractor_version"    => JSON::Any.new("1"),
      "extraction_config_id" => JSON::Any.new("cfg"),
      "status"               => JSON::Any.new("candidate"),
      "attribute"            => JSON::Any.new(attribute),
      "value"                => JSON::Any.new(value),
      "metadata"             => JSON::Any.new({} of String => JSON::Any),
    }.to_json)
  end

  def review(graph, candidate_id : String, decision : String, corrected_value : String? = nil)
    Chronicle::Packs::SubjectProfile.review_subject_fact_fn(
      graph,
      candidate_id,
      decision,
      corrected_value: corrected_value,
    )
  end
end

include SubjectProfileSpecSupport

describe Chronicle::Packs::SubjectProfile do
  describe "manifest-declared surface" do
    it "matches the upstream subject_profile manifest" do
      pack = Chronicle::Packs::SubjectProfile.pack
      pack.name.should eq("subject_profile")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq(
        ["subject_fact_verdict", "subject_fact", "subject_contradiction"]
      )
      pack.relation_types.map(&.name).should eq(
        ["verdict_for_profile_candidate", "promoted_from_profile_candidate", "subject_fact_grounded_in", "subject_fact_supersedes", "contradiction_involves"]
      )
      pack.behaviors.map(&.name).should eq(["apply_subject_fact_verdict"])
      pack.tools.map(&.name).should eq(["review_subject_fact", "forget_subject_fact"])
      pack.settings_schema.should eq("SubjectProfileSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(subject_profile_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::SubjectProfile.pack)
    end

    it "round-trips the closed-set subject_profile enums as underscored names" do
      Chronicle::Packs::SubjectProfile::VerdictDecision::Confirm.to_json.should eq(%("confirm"))
      Chronicle::Packs::SubjectProfile::VerdictStatus::Applied.to_json.should eq(%("applied"))
      Chronicle::Packs::SubjectProfile::FactStatus::Contradicted.to_json.should eq(%("contradicted"))
      Chronicle::Packs::SubjectProfile::FactStatus::Superseded.to_json.should eq(%("superseded"))
      Chronicle::Packs::SubjectProfile::ContradictionStatus::Resolved.to_json.should eq(%("resolved"))
    end
  end

  describe "apply_subject_fact_verdict" do
    it "confirms a candidate into a promoted subject fact with exact provenance" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph)
        candidate = add_candidate(graph, evidence, value: "Sarah Chen is the head of engineering")
        rt.run_until_idle

        review(graph, candidate.id, "confirm")
        rt.run_until_idle

        facts = graph.objects(type: "subject_fact")
        facts.size.should eq(1)
        fact = JSON.parse(facts.first.data)
        fact["subject_ref"].as_s.should eq("owner")
        fact["attribute"].as_s.should eq("profile_statement")
        fact["value"].as_s.should eq("Sarah Chen is the head of engineering")
        fact["status"].as_s.should eq("promoted")
        fact["confidence"].as_f.should eq(0.8)
        fact["trust"].as_f.should eq(0.9)
        fact["candidate_id"].as_s.should eq(candidate.id)
        fact["evidence_id"].as_s.should eq(evidence.id)
        fact["source_surface_id"].as_s.should eq("surf_owner_1")
        fact["verdict_id"].as_s.should eq(graph.objects(type: "subject_fact_verdict").first.id)
        fact["fact_identity"].as_s.should match(/\Asubject_fact_[0-9a-f]{24}\z/)

        verdict = JSON.parse(graph.objects(type: "subject_fact_verdict").first.data)
        verdict["status"].as_s.should eq("applied")
        verdict["result_fact_id"].as_s.should eq(facts.first.id)

        rel_types = graph.relations.map(&.type).to_set
        rel_types.should contain("verdict_for_profile_candidate")
        rel_types.should contain("promoted_from_profile_candidate")
        rel_types.should contain("subject_fact_grounded_in")
      end
    end

    it "rejects a candidate and invalidates it without creating a fact" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph)
        candidate = add_candidate(graph, evidence, value: "Sarah Chen is the head of engineering")
        rt.run_until_idle

        review(graph, candidate.id, "reject")
        rt.run_until_idle

        graph.objects(type: "subject_fact").size.should eq(0)
        verdict = JSON.parse(graph.objects(type: "subject_fact_verdict").first.data)
        verdict["status"].as_s.should eq("applied")
        candidate_data = JSON.parse(graph.get_object(candidate.id).not_nil!.data)
        candidate_data["status"].as_s.should eq("invalidated")
        candidate_data["invalidation_reason"].as_s.should eq("owner_rejected")
      end
    end

    it "fails closed when the candidate is not a profile_candidate" do
      with_subject_profile_runtime do |_store, graph, rt|
        other = graph.add_object("observation", {
          "text" => JSON::Any.new("not a candidate"),
        }.to_json)
        rt.run_until_idle

        graph.add_object("subject_fact_verdict", Chronicle::Packs::SubjectProfile::SubjectFactVerdict.new(
          candidate_id: other.id,
          subject_ref: "owner",
          decision: Chronicle::Packs::SubjectProfile::VerdictDecision::Confirm,
          status: Chronicle::Packs::SubjectProfile::VerdictStatus::Proposed,
        ).to_json)
        rt.run_until_idle

        graph.objects(type: "subject_fact").size.should eq(0)
        verdict = JSON.parse(graph.objects(type: "subject_fact_verdict").first.data)
        verdict["status"].as_s.should eq("failed")
      end
    end

    it "fails closed when the evidence scope is not owner_profile (security boundary)" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph, scope: "workspace_shared")
        candidate = add_candidate(graph, evidence, value: "Sarah Chen is the head of engineering")
        rt.run_until_idle

        review(graph, candidate.id, "confirm")
        rt.run_until_idle

        graph.objects(type: "subject_fact").size.should eq(0)
        verdict = JSON.parse(graph.objects(type: "subject_fact_verdict").first.data)
        verdict["status"].as_s.should eq("failed")
        verdict["metadata"].as_h["error"].as_s.should eq("owner_subject_scope_required")
      end
    end

    it "fails closed when the resulting value is empty" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph)
        candidate = add_candidate(graph, evidence, value: "")
        rt.run_until_idle

        review(graph, candidate.id, "confirm")
        rt.run_until_idle

        graph.objects(type: "subject_fact").size.should eq(0)
        verdict = JSON.parse(graph.objects(type: "subject_fact_verdict").first.data)
        verdict["status"].as_s.should eq("failed")
        verdict["metadata"].as_h["error"].as_s.should eq("empty_value")
      end
    end

    it "corrects a value and records a contradiction against the prior promoted fact" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph)
        c1 = add_candidate(graph, evidence, value: "Sarah Chen works at Acme")
        rt.run_until_idle
        review(graph, c1.id, "confirm")
        rt.run_until_idle

        c2 = add_candidate(graph, evidence, value: "Sarah Chen works at Acme")
        rt.run_until_idle
        review(graph, c2.id, "correct", corrected_value: "Sarah Chen is the CEO of Acme")
        rt.run_until_idle

        facts = graph.objects(type: "subject_fact")
        facts.size.should eq(2)
        by_status = facts.map { |f| JSON.parse(f.data)["status"].as_s }
        by_status.should contain("promoted")
        by_status.should contain("contradicted")
        values = facts.map { |f| JSON.parse(f.data)["value"].as_s }
        values.should contain("Sarah Chen works at Acme")
        values.should contain("Sarah Chen is the CEO of Acme")

        contradictions = graph.objects(type: "subject_contradiction")
        contradictions.size.should eq(1)
        contra = JSON.parse(contradictions.first.data)
        contra["attribute"].as_s.should eq("profile_statement")
        contra["status"].as_s.should eq("open")
        contra["winning_fact_id"]?.try(&.as_s?).should be_nil
        contra["rationale"].as_s.should eq("conflicting owner-confirmed values")
        contra["fact_ids"].as_a.size.should eq(2)

        graph.relations.select { |r| r.type == "contradiction_involves" }.size.should eq(2)
      end
    end
  end

  describe "fixture: manual forget workflow" do
    it "forgets a fact through an auditable superseding tombstone" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph)
        candidate = add_candidate(graph, evidence, value: "Sarah Chen is the head of engineering")
        rt.run_until_idle
        review(graph, candidate.id, "confirm")
        rt.run_until_idle

        fact = graph.objects(type: "subject_fact").first
        result = Chronicle::Packs::SubjectProfile.forget_subject_fact_fn(graph, fact.id)
        rt.run_until_idle

        result["status"].as_s.should eq("forgotten")
        result["fact_id"].as_s.should eq(fact.id)

        tombstone = graph.objects(type: "subject_fact").select { |f| f.id != fact.id }.first
        tdata = JSON.parse(tombstone.data)
        tdata["status"].as_s.should eq("forgotten")
        tdata["supersedes_fact_id"].as_s.should eq(fact.id)
        tdata["subject_ref"].as_s.should eq("owner")
        tdata["metadata"].as_h["forgotten_by"].as_s.should eq("owner")
        tdata["fact_identity"].as_s.should match(/\Asubject_fact_forget_[0-9a-f]{24}\z/)

        original = JSON.parse(graph.get_object(fact.id).not_nil!.data)
        original["status"].as_s.should eq("superseded")

        graph.relations.select { |r| r.type == "subject_fact_supersedes" }.size.should eq(1)
      end
    end

    it "raises when forgetting a non-subject_fact object" do
      with_subject_profile_runtime do |_store, graph, rt|
        other = graph.add_object("observation", {"text" => JSON::Any.new("nope")}.to_json)
        rt.run_until_idle
        expect_raises(Chronicle::Packs::PackError, /unknown subject_fact/) do
          Chronicle::Packs::SubjectProfile.forget_subject_fact_fn(graph, other.id)
        end
      end
    end
  end

  # Direct characterizations of vendor tests/test_subject_profile.py. Keep
  # these separate from the broader pack specs above so the scoped evidence,
  # explicit review, conflict, and append-only lifecycle contract remains
  # mechanically traceable in the parity ledger.
  describe "upstream test_subject_profile parity" do
    it "requires an explicit verdict and preserves the evidence provenance" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph, source_surface_id: "public_presence")
        candidate = add_candidate(graph, evidence, value: "ActiveGraph")
        rt.run_until_idle

        graph.objects(type: "subject_fact").should be_empty
        result = review(graph, candidate.id, "confirm")
        rt.run_until_idle

        fact = JSON.parse(graph.objects(type: "subject_fact").first.data)
        fact["evidence_id"].as_s.should eq(evidence.id)
        fact["source_surface_id"].as_s.should eq("public_presence")
        JSON.parse(graph.get_object(result["verdict_id"].as_s).not_nil!.data)["status"].as_s.should eq("applied")
      end
    end

    it "refuses connector evidence with no owner scope" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph, scope: nil)
        candidate = add_candidate(graph, evidence, value: "ActiveGraph")
        rt.run_until_idle

        result = review(graph, candidate.id, "confirm")
        rt.run_until_idle

        JSON.parse(graph.get_object(result["verdict_id"].as_s).not_nil!.data)["status"].as_s.should eq("failed")
        graph.objects(type: "subject_fact").should be_empty
      end
    end

    it "records conflict and forgetting as append-only fact lifecycles" do
      with_subject_profile_runtime do |_store, graph, rt|
        evidence = add_evidence(graph)
        first = add_candidate(graph, evidence, value: "ActiveGraph")
        rt.run_until_idle
        review(graph, first.id, "confirm")
        rt.run_until_idle

        second = add_candidate(graph, evidence, value: "BabyAGI")
        review(graph, second.id, "confirm")
        rt.run_until_idle

        graph.objects(type: "subject_contradiction").should_not be_empty
        current = graph.objects(type: "subject_fact").find do |fact|
          JSON.parse(fact.data)["status"].as_s == "promoted"
        end.not_nil!
        result = Chronicle::Packs::SubjectProfile.forget_subject_fact_fn(graph, current.id)
        rt.run_until_idle

        tombstone = JSON.parse(graph.get_object(result["tombstone_fact_id"].as_s).not_nil!.data)
        tombstone["status"].as_s.should eq("forgotten")
        JSON.parse(graph.get_object(current.id).not_nil!.data)["status"].as_s.should eq("superseded")
      end
    end
  end
end

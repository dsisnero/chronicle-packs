require "spec"
require "file_utils"
require "../spec_helper"

# P1 acceptance tests for local acquisition, normalization, and replay
# (upstream tests/test_activity_normalizer.py).
#
# Importers deliberately re-emit overlapping acquisition records; the
# normalizer's logical identities keep evidence, extraction records, and
# candidates idempotent downstream. This suite exercises the retained
# legacy extraction machinery (direct evidence→candidate writes, replay
# re-extraction) with `legacy_extraction_enabled: true` — the ADR 0026
# shared-path behavior is covered by the shared-extraction migration spec.

module ActivityNormalizerContractSpecSupport
  extend self

  FIXED_FILE_TIME = 1_704_067_200

  CANDIDATE_TYPES = {
    "memory_candidate",
    "preference_candidate",
    "task_candidate",
    "profile_candidate",
    "skill_candidate",
    "eval_candidate",
  }

  def pipeline(source_dir : Path, artifact_dir : Path) : {Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
    settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(
      artifact_store_dir: artifact_dir.to_s,
      legacy_extraction_enabled: true,
    )
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, Chronicle::Packs::Fixtures._settings_hash(settings)).should be_true
    rt.load_pack(Chronicle::Packs::LocalFiles.pack, Chronicle::Packs::Fixtures._settings_hash(
      Chronicle::Packs::LocalFiles::LocalFilesSettings.new(artifact_store_dir: artifact_dir.to_s)
    )).should be_true
    {graph, rt}
  end

  def write_source(root : Path, relative_path : String, text : String) : Path
    path = root / relative_path
    FileUtils.mkdir_p(path.parent.to_s)
    File.write(path.to_s, text)
    File.utime(Time.unix(FIXED_FILE_TIME), Time.unix(FIXED_FILE_TIME), path.to_s)
    path
  end

  def import(graph, rt, root : Path, artifact_dir : Path, *, replay_mode : String = "artifact")
    result = Chronicle::Packs::LocalFiles.import_local_files_fn(
      graph, root.to_s, "surface_local_acceptance",
      artifact_store_dir: artifact_dir.to_s,
      replay_mode: replay_mode,
      is_fixture: false,
    )
    rt.run_until_idle
    result
  end

  def candidates(graph) : Array(Chronicle::GraphObject)
    CANDIDATE_TYPES.to_a.flat_map { |type| graph.objects(type: type) }
  end

  def downstream_identity_snapshot(graph) : Hash(String, Array(String))
    cands = candidates(graph)
    {
      "evidence"          => graph.objects(type: "activity_evidence").map(&.id).sort,
      "extractions"       => graph.objects(type: "extraction_record").map(&.id).sort,
      "candidate_objects" => cands.map(&.id).sort,
      "candidate_keys"    => cands.map { |c| (JSON.parse(c.data).as_h["candidate_identity"]?.try(&.as_s?) || "legacy-core:#{c.id}") }.sort,
      "ingested_events"   => graph.events.select { |event| event.type == "source.event_ingested" }.map(&.id).sort,
    }
  end
end

include ActivityNormalizerContractSpecSupport

describe "activity_normalizer P1 acceptance" do
  it "repeat import produces no new evidence or downstream duplicates" do
    tmp = Path.new(Dir.tempdir) / "an_repeat_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      write_source(source, "notes/profile.md", "Remember: My name is Yohei.\nPreference: concise status updates.\n")

      first = import(graph, rt, source, artifacts)
      first["ok"].as_bool.should be_true
      first["imported"].as_i.should eq(1)
      before = downstream_identity_snapshot(graph)
      before["evidence"].size.should eq(1)
      before["extractions"].should_not be_empty
      before["candidate_objects"].should_not be_empty
      before["ingested_events"].size.should eq(1)

      second = import(graph, rt, source, artifacts)
      second["ok"].as_bool.should be_true
      second["imported"].as_i.should eq(1)
      downstream_identity_snapshot(graph).should eq(before)
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "overlapping snapshots reconcile by normalizer identity" do
    tmp = Path.new(Dir.tempdir) / "an_overlap_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      write_source(source, "a.md", "Remember: alpha is stable.\n")
      import(graph, rt, source, artifacts)["imported"].as_i.should eq(1)
      first_identity = JSON.parse(graph.objects(type: "activity_evidence").first.data)["evidence_identity"].as_s

      write_source(source, "b.md", "Remember: beta is new.\n")
      overlap = import(graph, rt, source, artifacts)
      overlap["imported"].as_i.should eq(2)

      evidence = graph.objects(type: "activity_evidence")
      evidence.size.should eq(2)
      identities = evidence.map { |item| JSON.parse(item.data)["evidence_identity"].as_s }
      identities.uniq.size.should eq(2)
      identities.count(first_identity).should eq(1)

      snapshot = downstream_identity_snapshot(graph)
      snapshot["extractions"].size.should eq(2)
      snapshot["candidate_objects"].size.should eq(candidates(graph).size)
      snapshot["candidate_keys"].size.should eq(candidates(graph).size)
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "an edited item creates a linked superseding revision" do
    tmp = Path.new(Dir.tempdir) / "an_edit_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      source_file = write_source(source, "changing.md", "Remember: deploy on Tuesday.\n")
      import(graph, rt, source, artifacts)["ok"].as_bool.should be_true
      original = graph.objects(type: "activity_evidence").first

      File.write(source_file.to_s, "Remember: deploy on Wednesday.\n")
      File.utime(Time.unix(FIXED_FILE_TIME), Time.unix(FIXED_FILE_TIME), source_file.to_s)
      import(graph, rt, source, artifacts)["ok"].as_bool.should be_true

      evidence = graph.objects(type: "activity_evidence").sort_by { |item| JSON.parse(item.data)["revision_number"].as_i }
      evidence.size.should eq(2)
      old, new = evidence
      old.id.should eq(original.id)
      JSON.parse(old.data)["evidence_identity"].as_s.should eq(JSON.parse(new.data)["evidence_identity"].as_s)
      [JSON.parse(old.data)["revision_number"].as_i, JSON.parse(new.data)["revision_number"].as_i].should eq([1, 2])
      JSON.parse(old.data)["status"].as_s.should eq("superseded")
      JSON.parse(new.data)["status"].as_s.should eq("current")
      JSON.parse(new.data)["supersedes_evidence_id"].as_s.should eq(old.id)
      JSON.parse(old.data)["content_hash"].as_s.should_not eq(JSON.parse(new.data)["content_hash"].as_s)
      graph.relations.any? do |relation|
        relation.type == "supersedes" && relation.from_id == new.id && relation.to_id == old.id
      end.should be_true
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "reextract after deleting the source uses the recorded artifact and verifies replay" do
    tmp = Path.new(Dir.tempdir) / "an_replay_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      write_source(source, "replay.md", "Remember: replay must not touch the original file.\n")
      import(graph, rt, source, artifacts)["ok"].as_bool.should be_true
      evidence = graph.objects(type: "activity_evidence").first
      evidence_data = JSON.parse(evidence.data)
      evidence_data["replay_complete"].as_bool.should be_true
      evidence_data["replay_payload_ref"].as_s.should start_with("artifact://sha256/")

      FileUtils.rm_rf(source)
      result = Chronicle::Packs::ActivityNormalizer.reextract_evidence_fn(
        graph, evidence.id,
        settings: Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifacts.to_s, legacy_extraction_enabled: true),
        extractor_id: "activity.structure",
        extractor_version: "0.1.0",
        extraction_config_id: "after-source-deletion",
      )
      result["ok"].as_bool.should be_true
      record = graph.get_object(result["extraction_record_id"].as_s).not_nil!
      record_data = JSON.parse(record.data)
      record_data["replayed"].as_bool.should be_true
      record_data["replay_verified"].as_bool.should be_true
      record_data["input_replay_payload_hash"].as_s.should eq(evidence_data["replay_payload_hash"].as_s)
      graph.events.any? { |event| event.type == "replay.verified" }.should be_true
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "reference_only records incomplete and replay fails loudly" do
    tmp = Path.new(Dir.tempdir) / "an_refonly_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      write_source(source, "private.md", "Remember: retained derived content has no replay payload.\n")
      import(graph, rt, source, artifacts, replay_mode: "reference_only")["ok"].as_bool.should be_true
      evidence = graph.objects(type: "activity_evidence").first
      evidence_data = JSON.parse(evidence.data)
      evidence_data["replay_mode"].as_s.should eq("reference_only")
      evidence_data["replay_complete"].as_bool.should be_false

      FileUtils.rm_rf(source)
      result = Chronicle::Packs::ActivityNormalizer.reextract_evidence_fn(
        graph, evidence.id,
        settings: Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifacts.to_s, legacy_extraction_enabled: true),
        extraction_config_id: "must-fail-without-payload",
      )
      result["ok"].as_bool.should be_false
      failure = graph.get_object(result["failure_id"].as_s).not_nil!
      failure.type.should eq("ingestion_failure")
      JSON.parse(failure.data)["stage"].as_s.should eq("replay")
      JSON.parse(failure.data)["message"].as_s.should contain("reference_only")
      graph.objects(type: "extraction_record").none? do |record|
        data = JSON.parse(record.data)
        data["extraction_config_id"]?.try(&.as_s?) == "must-fail-without-payload" && data["status"]?.try(&.as_s?) == "completed"
      end.should be_true
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "a lost replay artifact marks the evidence incomplete" do
    tmp = Path.new(Dir.tempdir) / "an_lost_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      write_source(source, "lost-artifact.md", "Remember: artifact loss must invalidate replay completeness.\n")
      import(graph, rt, source, artifacts)["ok"].as_bool.should be_true
      evidence = graph.objects(type: "activity_evidence").first
      evidence_data = JSON.parse(evidence.data)
      retained = Chronicle::Packs::ActivityNormalizer::Replay.artifact_path(
        artifacts.to_s, evidence_data["replay_payload_ref"].as_s,
      )
      File.delete(retained.to_s)

      result = Chronicle::Packs::ActivityNormalizer.reextract_evidence_fn(
        graph, evidence.id,
        settings: Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifacts.to_s, legacy_extraction_enabled: true),
        extraction_config_id: "missing-artifact",
      )
      result["ok"].as_bool.should be_false
      JSON.parse(graph.get_object(evidence.id).not_nil!.data)["replay_complete"].as_bool.should be_false
      failure = graph.get_object(result["failure_id"].as_s).not_nil!
      failure_data = JSON.parse(failure.data)
      failure_data["stage"].as_s.should eq("replay")
      failure_data["error_code"].as_s.should eq("replay_unavailable")
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "every candidate has full evidence and version provenance links" do
    tmp = Path.new(Dir.tempdir) / "an_prov_#{Random::Secure.hex(4)}"
    source = tmp / "source"
    artifacts = tmp / "artifacts"
    FileUtils.mkdir_p(source.to_s)
    begin
      graph, rt = pipeline(source, artifacts)
      write_source(source, "provenance.md", [
        "Remember: The project codename is ActiveGraph.",
        "Preference: I prefer concise written updates.",
        "TODO: document the deterministic replay contract.",
        "Profile: I maintain the local knowledge source.",
        "Skill: summarize a source with citations.",
        "Evaluation: the importer result was helpful.",
      ].join("\n"))
      import(graph, rt, source, artifacts)["ok"].as_bool.should be_true

      cands = candidates(graph)
      cands.should_not be_empty
      relations = graph.relations

      cands.each do |candidate|
        evidence_links = relations.select { |relation| relation.type == "extracted_from" && relation.from_id == candidate.id }
        evidence_links.size.should eq(1), candidate.id
        evidence = graph.get_object(evidence_links.first.to_id).not_nil!
        evidence.type.should eq("activity_evidence")
        evidence_data = JSON.parse(evidence.data)
        evidence_data["importer_id"].as_s.should eq("local_files")
        evidence_data["source_ref"].as_s.should_not be_empty
        evidence_data["source_surface_id"].as_s.should eq("surface_local_acceptance")

        extraction_links = relations.select { |relation| relation.type == "produced_candidate" && relation.to_id == candidate.id }
        extraction_links.size.should eq(1), candidate.id
        extraction = graph.get_object(extraction_links.first.from_id).not_nil!
        extraction.type.should eq("extraction_record")
        extraction_data = JSON.parse(extraction.data)
        extraction_data["evidence_id"].as_s.should eq(evidence.id)
        extraction_data["evidence_identity"].as_s.should eq(evidence_data["evidence_identity"].as_s)
        extraction_data["revision_id"].as_s.should eq(evidence_data["revision_id"].as_s)
        extraction_data["extractor_id"].as_s.should_not be_empty
        extraction_data["extractor_version"].as_s.should_not be_empty
        extraction_data["extraction_config_id"].as_s.should_not be_empty
        extraction_data["candidate_ids"].as_a.map(&.as_s).should contain(candidate.id)

        candidate_data = JSON.parse(candidate.data)
        if candidate.type == "memory_candidate"
          candidate_data["source_ids"].as_a.map(&.as_s).should contain(evidence.id)
        else
          candidate_data["evidence_id"].as_s.should eq(evidence.id)
          candidate_data["evidence_identity"].as_s.should eq(evidence_data["evidence_identity"].as_s)
          candidate_data["revision_id"].as_s.should eq(evidence_data["revision_id"].as_s)
        end
      end
    ensure
      FileUtils.rm_rf(tmp)
    end
  end
end

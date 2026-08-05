require "spec"
require "digest"
require "file_utils"
require "../spec_helper"

# Activity Normalizer pack (packs/activity_normalizer): provider-neutral
# evidence identity and deterministic extraction. Ported slice 1: the object
# surface, the StructureExtractor, replay-payload normalization, and the
# normalize_acquired_item behavior (with legacy extraction opt-in). The
# remaining behaviors/tools/replay store are deferred.

module ActivityNormalizerSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  TMPDIR = begin
    path = Path[__DIR__].parent.parent / "tmp" / "replay_artifact_test"
    FileUtils.rm_rf(path)
    FileUtils.mkdir_p(path)
    path.to_s
  end

  def tmpdir : String
    TMPDIR
  end

  def with_normalizer_runtime(settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    end
    yield store, graph, rt
  end

  def add_acquired_item(graph : Chronicle::GraphProjection, source_surface_id : String = "chat/sess_1", dedup_key : String = "dedup_1", source_ref : String = "msg_1", content : String = "preference: I prefer dark mode\nTODO: ship the report", source_hash : String? = nil)
    item = graph.add_object("acquired_item", JSON.build do |json|
      json.object do
        json.field "source_surface_id", source_surface_id
        json.field "provider_item_id", "p1"
        json.field "dedup_key", dedup_key
        json.field "source_ref", source_ref
        json.field "source_hash", source_hash || "0" * 64
        json.field "provider_time", "2026-07-01T00:00:00Z"
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "media_type", "text/plain"
        json.field "importer_id", "chatgpt_export"
        json.field "importer_version", "1.0.0"
      end
    end)
    graph.add_object("acquired_content", JSON.build do |json|
      json.object do
        json.field "acquired_item_id", item.id
        json.field "normalized_content", content
        json.field "normalized_metadata", {} of String => JSON::Any
        json.field "source_category", "communication"
        json.field "connection_path", "export"
        json.field "is_fixture", true
      end
    end)
    item
  end
end

include ActivityNormalizerSpecSupport

private alias Replay = Chronicle::Packs::ActivityNormalizer::Replay

describe Chronicle::Packs::ActivityNormalizer do
  describe "StructureExtractor" do
    it "extracts memory, preference, task, profile, skill, and eval candidates" do
      extractor = Chronicle::Packs::ActivityNormalizer::Extractors::StructureExtractor.new
      drafts = extractor.extract(
        "remember: the api key rotates quarterly\npreference: I prefer dark mode\ntask: ship the report\nevaluation: helpful\neval: the answer helped", {} of String => JSON::Any,
        max_candidates: 32, max_candidate_chars: 2000
      )
      kinds = drafts.map(&.kind)
      kinds.should contain("memory")
      kinds.should contain("preference")
      kinds.should contain("task")
      kinds.should contain("eval")
    end

    it "deduplicates identical kind/text candidates preserving first order" do
      extractor = Chronicle::Packs::ActivityNormalizer::Extractors::StructureExtractor.new
      drafts = extractor.extract(
        "preference: dark mode\nPREFERENCE: dark mode\ntask: ship", {} of String => JSON::Any,
        max_candidates: 32, max_candidate_chars: 2000
      )
      drafts.count { |d| d.kind == "preference" }.should eq(1)
    end
  end

  describe "normalize_replay_payload" do
    it "derives text from a JSON payload with normalized_content" do
      payload = %({"normalized_content":"the meeting decided X","source":"email"})
      content, metadata = Chronicle::Packs::ActivityNormalizer.normalize_replay_payload(payload.to_slice, "application/json", encoding: "utf-8", max_chars: 16_000)
      content.should eq("the meeting decided X")
      metadata["source"].as_s.should eq("email")
    end

    it "normalizes line endings and truncates" do
      content, _ = Chronicle::Packs::ActivityNormalizer.normalize_replay_payload("a\r\nb\r\nc".to_slice, "text/plain", encoding: "utf-8", max_chars: 16)
      content.should eq("a\nb\nc")
      Chronicle::Packs::ActivityNormalizer.normalize_replay_payload("0123456789".to_slice, "text/plain", encoding: "utf-8", max_chars: 4)[0].should eq("0123")
    end
  end

  describe "normalize_acquired_item" do
    it "owns evidence identity and creates an activity_evidence revision" do
      with_normalizer_runtime do |_store, graph, rt|
        add_acquired_item(graph)
        rt.run_until_idle

        evidence = graph.objects(type: "activity_evidence")
        evidence.size.should eq(1)
        data = JSON.parse(evidence.first.data)
        data["evidence_identity"].as_s.should eq("evidence_#{Digest::SHA256.hexdigest("chat/sess_1\x1fdedup_1")}")
        data["revision_number"].as_i.should eq(1)
        data["status"].as_s.should eq("current")
        data["replay_complete"].as_bool.should be_false
        data["normalized_content"].as_s.should contain("preference")

        graph.relations(source: evidence.first.id, type: "acquired_from").size.should eq(1)
        graph.relations(type: "content_for").size.should eq(1)
        graph.relations(type: "normalizes_to").size.should eq(1)
      end
    end

    it "supersedes the prior revision on changed content" do
      with_normalizer_runtime do |_store, graph, rt|
        add_acquired_item(graph, dedup_key: "dedup_x", content: "version one", source_hash: "1" * 64)
        rt.run_until_idle
        add_acquired_item(graph, dedup_key: "dedup_x", content: "version two changed", source_hash: "2" * 64)
        rt.run_until_idle

        evidence = graph.objects(type: "activity_evidence")
        evidence.size.should eq(2)
        revisions = evidence.map { |obj| JSON.parse(obj.data)["revision_number"].as_i }.sort
        revisions.should eq([1, 2])

        current = evidence.find { |obj| JSON.parse(obj.data)["status"].as_s == "current" }
        JSON.parse(current.not_nil!.data)["revision_number"].as_i.should eq(2)
        superseded = evidence.find { |obj| JSON.parse(obj.data)["status"].as_s == "superseded" }
        JSON.parse(superseded.not_nil!.data)["revision_number"].as_i.should eq(1)
        graph.relations(type: "supersedes").size.should eq(1)
      end
    end

    it "is idempotent for identical content (same content hash)" do
      with_normalizer_runtime do |_store, graph, rt|
        add_acquired_item(graph, dedup_key: "dedup_same", content: "identical")
        rt.run_until_idle
        add_acquired_item(graph, dedup_key: "dedup_same", content: "identical")
        rt.run_until_idle

        graph.objects(type: "activity_evidence").size.should eq(1)
      end
    end

    it "records a failure when content is missing" do
      with_normalizer_runtime do |_store, graph, rt|
        graph.add_object("acquired_item", JSON.build do |json|
          json.object do
            json.field "source_surface_id", "chat/s1"
            json.field "dedup_key", "d1"
            json.field "source_ref", "r1"
            json.field "replay_mode", "reference_only"
            json.field "replay_payload_ref", ""
            json.field "replay_payload_hash", "0" * 64
            json.field "media_type", "text/plain"
            json.field "importer_id", "i"
            json.field "importer_version", "1"
          end
        end)
        rt.run_until_idle

        failures = graph.objects(type: "ingestion_failure")
        failures.size.should eq(1)
        JSON.parse(failures.first.data)["error_code"].as_s.should eq("missing_acquired_content")
      end
    end
  end

  describe "legacy extraction (run_extraction)" do
    it "runs the structure extractor and records candidates when enabled" do
      with_normalizer_runtime(Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.from_json(%({"legacy_extraction_enabled":true}))) do |_store, graph, rt|
        add_acquired_item(graph, content: "preference: dark mode\ntask: ship the report")
        rt.run_until_idle

        records = graph.objects(type: "extraction_record")
        records.size.should eq(1)
        record_data = JSON.parse(records.first.data)
        record_data["status"].as_s.should eq("completed")

        candidates = graph.objects(type: "preference_candidate")
        candidates.size.should eq(1)
        JSON.parse(candidates.first.data)["candidate_identity"].as_s.should match(/^candidate_/)
        graph.relations(type: "produced_candidate").size.should eq(3)
        graph.relations(type: "extracted_from").size.should eq(3)
      end
    end
  end

  describe "replay store" do
    it "hashes payloads and builds canonical artifact references" do
      Replay.sha256_hex("hello").should eq(Digest::SHA256.hexdigest("hello"))
      Replay.artifact_ref_for_hash("a" * 64).should eq("artifact://sha256/aa/#{"a" * 64}")
      expect_raises(ArgumentError) { Replay.artifact_ref_for_hash("not-a-digest") }
    end

    it "round-trips portable artifact locators" do
      digest = "ab" * 32
      ref, roundtripped = Replay.artifact_identity_from_locator(Replay.portable_artifact_locator(digest))
      ref.should eq(Replay.artifact_ref_for_hash(digest))
      roundtripped.should eq(digest)
    end

    it "stores and reads content-addressed artifacts with size and integrity checks" do
      Dir.mkdir_p(tmpdir)
      ref, digest = Replay.store_replay_artifact("hello world", tmpdir)
      String.new(Replay.read_artifact(ref, digest, tmpdir, max_bytes: 1024)).should eq("hello world")
      expect_raises(Replay::ReplayUnavailableError) { Replay.read_artifact(ref, digest, tmpdir, max_bytes: 1) }
    end

    it "read_replay_payload verifies inline payloads and rejects reference_only" do
      payload = "preference: dark mode"
      evidence = JSON.parse(JSON.build do |json|
        json.object do
          json.field "replay_mode", "inline"
          json.field "replay_payload_ref", payload
          json.field "replay_payload_hash", Digest::SHA256.hexdigest(payload)
        end
      end).as_h
      String.new(Replay.read_replay_payload(evidence, Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new)).should eq(payload)

      reference_only = JSON.parse(%({"replay_mode":"reference_only","replay_payload_ref":"","replay_payload_hash":""})).as_h
      expect_raises(Replay::ReplayUnavailableError) { Replay.read_replay_payload(reference_only, Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new) }
    end
  end

  describe "cursor behaviors" do
    it "publishes source.cursor_advanced on cursor creation" do
      with_normalizer_runtime do |_store, graph, rt|
        graph.add_object("backfill_cursor", JSON.build do |json|
          json.object do
            json.field "source_surface_id", "gmail/acc_1"
            json.field "oldest_ingested_ref", "100"
            json.field "newest_ingested_ref", "200"
            json.field "watermark_ref", "42"
            json.field "cursor_version", 1
          end
        end)
        rt.run_until_idle

        graph.events.any? { |e| e.type == "source.cursor_advanced" }.should be_true
      end
    end

    it "publishes source.cursor_advanced on a cursor patch" do
      with_normalizer_runtime do |_store, graph, rt|
        cursor = graph.add_object("backfill_cursor", JSON.build do |json|
          json.object do
            json.field "source_surface_id", "gmail/acc_1"
            json.field "cursor_version", 1
          end
        end)
        rt.run_until_idle
        patch_value = JSON.build { |p| p.object { p.field "source_surface_id", "gmail/acc_1"; p.field "newest_ingested_ref", "250"; p.field "cursor_version", 2 } }
        patch_payload = JSON.build do |json|
          json.object do
            json.field "target", cursor.id
            json.field "patch" do
              json.object do
                json.field "id", "patch_1"
                json.field "target", cursor.id
                json.field "op", "update"
                json.field "value" do
                  json.raw(patch_value)
                end
                json.field "expected_version", 1
                json.field "proposed_by", "system"
              end
            end
          end
        end
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 99_u64, id: "patch_applied_1", type: "patch.applied",
          actor: "system", caused_by: nil,
          payload: patch_payload,
        ))
        rt.run_until_idle

        graph.events.count { |e| e.type == "source.cursor_advanced" }.should eq(2)
      end
    end
  end

  describe "fulfill_evidence_invalidation_request" do
    it "revokes matching current evidence and fulfills the request" do
      with_normalizer_runtime do |_store, graph, rt|
        add_acquired_item(graph)
        rt.run_until_idle
        evidence = graph.objects(type: "activity_evidence").first
        evidence_id = evidence.id

        graph.add_object("evidence_invalidation_request", JSON.build do |json|
          json.object do
            json.field "request_identity", "req_1"
            json.field "source_surface_id", "chat/sess_1"
            json.field "provider_item_id", "p1"
            json.field "reason", "provider_deleted"
            json.field "status", "proposed"
          end
        end)
        rt.run_until_idle

        revoked = graph.get_object(evidence_id)
        JSON.parse(revoked.not_nil!.data)["status"].as_s.should eq("revoked")
        request = graph.objects(type: "evidence_invalidation_request").first
        request_data = JSON.parse(request.data)
        request_data["status"].as_s.should eq("fulfilled")
        request_data["invalidated_evidence_ids"].as_a.should contain(JSON::Any.new(evidence_id))
        graph.events.any? { |e| e.type == "source.evidence_invalidated" }.should be_true
      end
    end
  end

  describe "tools" do
    it "reextract_evidence re-runs the extractor from retained payload" do
      with_normalizer_runtime do |_store, graph, rt|
        Chronicle::Packs::ActivityNormalizer.bound_graph = graph
        payload = "preference: dark mode"
        graph.add_object("acquired_item", JSON.build do |json|
          json.object do
            json.field "source_surface_id", "chat/sess_tool"
            json.field "provider_item_id", "p_tool"
            json.field "dedup_key", "dedup_tool"
            json.field "source_ref", "msg_tool"
            json.field "source_hash", "3" * 64
            json.field "replay_mode", "inline"
            json.field "replay_payload_ref", payload
            json.field "replay_payload_hash", Digest::SHA256.hexdigest(payload)
            json.field "media_type", "text/plain"
            json.field "importer_id", "chatgpt_export"
            json.field "importer_version", "1.0.0"
          end
        end)
        graph.add_object("acquired_content", JSON.build do |json|
          json.object do
            json.field "acquired_item_id", graph.objects(type: "acquired_item").first.id
            json.field "normalized_content", payload
            json.field "normalized_metadata", {} of String => JSON::Any
            json.field "source_category", "communication"
            json.field "connection_path", "export"
            json.field "is_fixture", true
          end
        end)
        rt.run_until_idle
        evidence = graph.objects(type: "activity_evidence").first

        result = Chronicle::Packs::ActivityNormalizer.reextract_evidence_fn(graph, evidence.id, settings: Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new, extractor_id: "activity.structure", extractor_version: "0.1.0", extraction_config_id: "default")

        result["ok"].as_bool.should be_true
        graph.events.any? { |e| e.type == "replay.verified" }.should be_true
        graph.relations(type: "extraction_for").size.should eq(1)
      ensure
        Chronicle::Packs::ActivityNormalizer.bound_graph = nil
      end
    end

    it "disable_extractor_version invalidates records and candidates" do
      with_normalizer_runtime(Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.from_json(%({"legacy_extraction_enabled":true}))) do |_store, graph, rt|
        Chronicle::Packs::ActivityNormalizer.bound_graph = graph
        add_acquired_item(graph, content: "preference: dark mode\ntask: ship the report", source_hash: "4" * 64)
        rt.run_until_idle

        result = Chronicle::Packs::ActivityNormalizer.disable_extractor_version_fn(graph, "activity.structure", "0.1.0", reason: "deprecated", extraction_config_id: nil)

        result["ok"].as_bool.should be_true
        result["invalidated_records"].as_i.should eq(1)
        result["invalidated_candidates"].as_i.should eq(3)
        states = graph.objects(type: "extractor_version_state")
        states.size.should eq(1)
        JSON.parse(states.first.data)["status"].as_s.should eq("disabled")
        records = graph.objects(type: "extraction_record")
        JSON.parse(records.first.data)["status"].as_s.should eq("invalidated")
        candidates = graph.objects(type: "preference_candidate")
        JSON.parse(candidates.first.data)["status"].as_s.should eq("invalidated")
      ensure
        Chronicle::Packs::ActivityNormalizer.bound_graph = nil
      end
    end
  end
end

require "spec"
require "digest"
require "file_utils"
require "../spec_helper"

# Local Files importer (packs/importers/local_files): bounded, deterministic
# directory snapshots for UTF-8 text, Markdown, and JSON, emitted through
# Activity Normalizer's acquired-item contract. Translated from upstream
# packs/importers/local_files/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# The importer is a format adapter only: it records `acquired_item` +
# `acquired_content` pairs (and `backfill_cursor` progress /
# `ingestion_failure`s); identity, dedup, evidence, and candidates are
# normalizer-owned.

module LocalFilesSpecSupport
  extend self

  def with_local_files_runtime(artifact_store_dir : String = ".activegraph/replay-artifacts", &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifact_store_dir)
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(settings.to_json).as_h).should be_true
    settings_lf = Chronicle::Packs::LocalFiles::LocalFilesSettings.new
    rt.load_pack(Chronicle::Packs::LocalFiles.pack, JSON.parse(settings_lf.to_json).as_h).should be_true
    yield store, graph, rt
  end

  def with_temp_dir(&)
    tmp = Path.new(Dir.tempdir) / "local_files_#{Random::Secure.hex(6)}"
    FileUtils.mkdir_p(tmp)
    begin
      yield tmp
    ensure
      FileUtils.rm_rf(tmp)
    end
  end
end

include LocalFilesSpecSupport

describe Chronicle::Packs::LocalFiles do
  describe "manifest-declared surface" do
    it "matches the upstream local_files manifest" do
      pack = Chronicle::Packs::LocalFiles.pack
      pack.name.should eq("local_files")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq([] of String)
      pack.relation_types.map(&.name).should eq([] of String)
      pack.behaviors.map(&.name).should eq([] of String)
      pack.tools.map(&.name).should eq(["import_local_files"])
      pack.settings_schema.should eq("LocalFilesSettings")
    end

    it "declares LocalFilesSettings with upstream defaults" do
      s = Chronicle::Packs::LocalFiles::LocalFilesSettings.new
      s.artifact_store_dir.should eq(".activegraph/replay-artifacts")
      s.replay_mode.should eq("artifact")
      s.max_files.should eq(1000)
      s.max_file_bytes.should eq(2_000_000)
      s.max_normalized_chars.should eq(8192)
      s.extensions.should eq([".txt", ".md", ".markdown", ".json"])
    end
  end

  describe "import_local_files_fn" do
    it "acquires a sorted snapshot with artifact replay + cursor progress" do
      with_temp_dir do |base|
        store = base / "replay"
        with_local_files_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          root = base / "knowledge"
          FileUtils.mkdir_p(root / "nested")
          File.write(root / "z.md", "# Last\n\nA deterministic note.\n")
          File.write(root / "a.txt", "The user prefers concise reports.\n")
          File.write(root / "nested" / "b.json", %({"task": "prepare the weekly brief", "done": false}\n))

          result = Chronicle::Packs::LocalFiles.import_local_files_fn(
            graph, root.to_s, "surface_local_fixture",
            artifact_store_dir: store.to_s, is_fixture: true,
          )
          rt.run_until_idle

          result["ok"].as_bool.should be_true
          result["imported"].as_i.should eq(3)

          items = graph.objects(type: "acquired_item")
          items.map { |o| JSON.parse(o.data)["provider_item_id"].as_s }.should eq(["a.txt", "nested/b.json", "z.md"])

          contents = graph.objects(type: "acquired_content")
          contents.size.should eq(3)
          contents.each do |c|
            cd = JSON.parse(c.data)
            cd["source_category"].as_s.should eq("local_knowledge")
            cd["connection_path"].as_s.should eq("local")
            cd["is_fixture"].as_bool.should be_true
          end

          items.each do |item|
            idata = JSON.parse(item.data)
            digest = idata["replay_payload_hash"].as_s
            idata["replay_payload_ref"].as_s.should eq("artifact://sha256/#{digest[0, 2]}/#{digest}")
            File.exists?((store / "sha256" / digest[0, 2] / digest).to_s).should be_true
          end

          cursors = graph.objects(type: "backfill_cursor")
          cursors.size.should eq(1)
          cdata = JSON.parse(cursors.first.data)
          cdata["oldest_ingested_ref"].as_s.should eq("a.txt")
          cdata["newest_ingested_ref"].as_s.should eq("z.md")
        end
      end
    end

    it "records a failure for malformed JSON and keeps valid siblings" do
      with_temp_dir do |base|
        with_local_files_runtime(artifact_store_dir: (base / "replay").to_s) do |_store, graph, rt|
          root = base / "knowledge"
          FileUtils.mkdir_p(root)
          File.write(root / "good.txt", "A valid sibling remains committed.\n")
          File.write(root / "bad.json", "{\"unterminated\": ")

          result = Chronicle::Packs::LocalFiles.import_local_files_fn(
            graph, root.to_s, "surface_malformed_fixture",
            artifact_store_dir: (base / "replay").to_s, is_fixture: true,
          )
          rt.run_until_idle

          result["ok"].as_bool.should be_false
          result["imported"].as_i.should eq(1)
          result["failed"].as_i.should eq(1)

          items = graph.objects(type: "acquired_item")
          items.map { |o| JSON.parse(o.data)["provider_item_id"].as_s }.should eq(["good.txt"])

          failures = graph.objects(type: "ingestion_failure")
          failures.size.should eq(1)
          fdata = JSON.parse(failures.first.data)
          fdata["error_code"].as_s.should eq("invalid_json")
          fdata["metadata"].as_h["provider_item_id"].as_s.should eq("bad.json")
        end
      end
    end

    it "reference-only keeps derived content but never retains replay bytes" do
      with_local_files_runtime do |_store, graph, rt|
        with_temp_dir do |base|
          root = base / "knowledge"
          FileUtils.mkdir_p(root)
          File.write(root / "private.md", "# Licensed note\n\nThe user prefers the morning review.\n")

          result = Chronicle::Packs::LocalFiles.import_local_files_fn(
            graph, root.to_s, "surface_reference_fixture",
            artifact_store_dir: (base / "replay").to_s,
            replay_mode: "reference_only", is_fixture: true,
          )
          rt.run_until_idle

          result["imported"].as_i.should eq(1)
          item = graph.objects(type: "acquired_item").first
          JSON.parse(item.data)["replay_payload_ref"].as_s.should eq("reference_only:no-payload")
          File.exists?((base / "replay").to_s).should be_false

          content = graph.objects(type: "acquired_content").first
          JSON.parse(content.data)["normalized_content"].as_s.should contain("Licensed note")

          evidence = graph.objects(type: "activity_evidence")
          evidence.size.should eq(1)
          JSON.parse(evidence.first.data)["replay_complete"].as_bool.should be_false
        end
      end
    end

    it "fails closed on an invalid root with a recoverable ingestion_failure" do
      with_local_files_runtime do |_store, graph, rt|
        result = Chronicle::Packs::LocalFiles.import_local_files_fn(
          graph, "/nonexistent/does-not-exist", "surface_bad_root",
        )
        result["ok"].as_bool.should be_false
        result["failed"].as_i.should eq(1)
        failures = graph.objects(type: "ingestion_failure")
        failures.size.should eq(1)
        JSON.parse(failures.first.data)["error_code"].as_s.should eq("invalid_root")
      end
    end

    it "rejects unsupported replay modes and empty source_surface_id" do
      with_local_files_runtime do |_store, graph, _rt|
        expect_raises(Chronicle::Packs::PackError, /unsupported replay_mode/) do
          Chronicle::Packs::LocalFiles.import_local_files_fn(graph, "/tmp", "s", replay_mode: "bogus")
        end
        expect_raises(Chronicle::Packs::PackError, /source_surface_id is required/) do
          Chronicle::Packs::LocalFiles.import_local_files_fn(graph, "/tmp", "")
        end
      end
    end

    it "JSON content is normalized (compact sorted keys) and metadata carries the shape" do
      with_local_files_runtime do |_store, graph, rt|
        with_temp_dir do |base|
          root = base / "knowledge"
          FileUtils.mkdir_p(root)
          File.write(root / "data.json", %({"b": 2, "a": 1, "s": "hi"}\n))

          Chronicle::Packs::LocalFiles.import_local_files_fn(
            graph, root.to_s, "surface_json", replay_mode: "inline")
          rt.run_until_idle

          content = graph.objects(type: "acquired_content").first
          cd = JSON.parse(content.data)
          cd["normalized_content"].as_s.should eq(%({"a":1,"b":2,"s":"hi"}))
          meta = cd["normalized_metadata"].as_h
          meta["json_root_type"].as_s.should eq("object")
          meta["json_top_level_keys"].as_a.map(&.as_s).should eq(["a", "b", "s"])
        end
      end
    end
  end
end

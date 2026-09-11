require "spec"
require "json"
require "file_utils"
require "compress/zip"
require "../spec_helper"

# Official ChatGPT export importer (packs/importers/chatgpt_export): bounded
# deterministic ingestion of ChatGPT export ZIPs, including canonical
# conversation paths and abandoned edit/regeneration branches. Translated
# from upstream packs/importers/chatgpt_export/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# conversations.json is a tree, not a transcript. The path ending at the
# provider's current_node is emitted as canonical conversation evidence;
# every other message node is also emitted and explicitly marked as an
# abandoned branch (a correction signal).

module ChatGPTExportSpecSupport
  extend self

  def with_chatgpt_runtime(artifact_store_dir : String = ".activegraph/replay-artifacts", &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifact_store_dir)
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(settings.to_json).as_h).should be_true
    settings_c = Chronicle::Packs::ChatGPTExport::ChatGPTExportSettings.new
    rt.load_pack(Chronicle::Packs::ChatGPTExport.pack, JSON.parse(settings_c.to_json).as_h).should be_true
    yield store, graph, rt
  end

  def with_temp_dir(&)
    tmp = Path.new(Dir.tempdir) / "chatgpt_#{Random::Secure.hex(6)}"
    FileUtils.mkdir_p(tmp)
    begin
      yield tmp
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  # Write a ZIP containing conversations.json with the given payload.
  def write_export(path : Path, payload : JSON::Any)
    Compress::Zip::Writer.open(path) do |zip|
      zip.add("conversations.json", payload.to_json)
    end
  end

  # A branched conversation (wrapped in the export's list root): root →
  # user-1 → [assistant-old (abandoned), assistant-current (canonical)].
  def branched_conversation : JSON::Any
    JSON.parse(%([{
      "id": "conversation-1",
      "title": "A corrected answer",
      "current_node": "assistant-current",
      "mapping": {
        "root": { "id": "root", "parent": null, "children": ["user-1"], "message": null },
        "user-1": {
          "id": "user-1", "parent": "root", "children": ["assistant-old", "assistant-current"],
          "message": {
            "id": "user-1", "author": {"role": "user"},
            "create_time": 1700000000, "status": "finished_successfully",
            "content": {"content_type": "text", "parts": ["Please revise this."]}
          }
        },
        "assistant-old": {
          "id": "assistant-old", "parent": "user-1", "children": [],
          "message": {
            "id": "assistant-old", "author": {"role": "assistant"},
            "create_time": 1700000001, "status": "finished_successfully",
            "content": {"content_type": "text", "parts": ["Abandoned answer"]}
          }
        },
        "assistant-current": {
          "id": "assistant-current", "parent": "user-1", "children": [],
          "message": {
            "id": "assistant-current", "author": {"role": "assistant"},
            "create_time": 1700000002, "status": "finished_successfully",
            "content": {"content_type": "text", "parts": ["Current answer"]}
          }
        }
      }
    }]))
  end
end

include ChatGPTExportSpecSupport

describe Chronicle::Packs::ChatGPTExport do
  describe "manifest-declared surface" do
    it "matches the upstream chatgpt_export manifest" do
      pack = Chronicle::Packs::ChatGPTExport.pack
      pack.name.should eq("chatgpt_export")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq([] of String)
      pack.relation_types.map(&.name).should eq([] of String)
      pack.behaviors.map(&.name).should eq([] of String)
      pack.tools.map(&.name).should eq(["import_chatgpt_export"])
      pack.settings_schema.should eq("ChatGPTExportSettings")
    end

    it "declares settings with upstream defaults" do
      s = Chronicle::Packs::ChatGPTExport::ChatGPTExportSettings.new
      s.artifact_store_dir.should eq(".activegraph/replay-artifacts")
      s.replay_mode.should eq("artifact")
      s.max_archive_bytes.should eq(1_000_000_000)
      s.max_conversations_json_bytes.should eq(256_000_000)
      s.max_compression_ratio.should eq(200)
      s.max_conversations.should eq(10_000)
      s.max_nodes_per_conversation.should eq(100_000)
      s.max_messages.should eq(250_000)
      s.max_normalized_chars.should eq(32_000)
    end
  end

  describe "import_chatgpt_export_fn" do
    it "imports canonical and abandoned branches with correct counts" do
      with_temp_dir do |base|
        archive = base / "export.zip"
        write_export(archive, branched_conversation)
        with_chatgpt_runtime(artifact_store_dir: (base / "artifacts").to_s) do |_store, graph, rt|
          result = Chronicle::Packs::ChatGPTExport.import_chatgpt_export_fn(
            graph, archive.to_s, "surface_chatgpt",
            artifact_store_dir: (base / "artifacts").to_s,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_true
          result["imported"].as_i.should eq(3)
          result["canonical_messages"].as_i.should eq(2)
          result["abandoned_messages"].as_i.should eq(1)

          contents = graph.objects(type: "acquired_content")
          abandoned = contents.select do |c|
            meta = JSON.parse(c.data)["normalized_metadata"].as_h
            meta["correction_signal"]?.try(&.as_bool?) == true
          end
          abandoned.size.should eq(1)
          JSON.parse(abandoned.first.data)["normalized_content"].as_s.should eq("Abandoned answer")
          abandoned_meta = JSON.parse(abandoned.first.data)["normalized_metadata"].as_h
          abandoned_meta["branch_status"].as_s.should eq("abandoned")
          abandoned_meta["nearest_canonical_ancestor_id"].as_s.should eq("user-1")

          by_node = contents.to_h do |content|
            metadata = JSON.parse(content.data)["normalized_metadata"].as_h
            {metadata["node_id"].as_s, metadata}
          end
          by_node["user-1"]["branch_status"].as_s.should eq("canonical")
          by_node["assistant-current"]["branch_status"].as_s.should eq("canonical")
          by_node["assistant-old"]["branch_status"].as_s.should eq("abandoned")
          by_node["user-1"]["canonical_path_index"].as_i.should be < by_node["assistant-current"]["canonical_path_index"].as_i
          by_node["assistant-old"]["canonical_path_index"].raw.should be_nil

          evidence_by_node = graph.objects(type: "activity_evidence").to_h do |evidence|
            metadata = JSON.parse(evidence.data)["normalized_metadata"].as_h
            {metadata["node_id"].as_s, evidence}
          end
          evidence_by_node.size.should eq(3)
          JSON.parse(evidence_by_node["assistant-current"].data)["normalized_metadata"].as_h["branch_status"].as_s.should eq("canonical")
          JSON.parse(evidence_by_node["assistant-old"].data)["normalized_metadata"].as_h["branch_status"].as_s.should eq("abandoned")

          items = graph.objects(type: "acquired_item")
          items.each do |item|
            JSON.parse(item.data)["replay_payload_ref"].as_s.should match(/^artifact:\/\/sha256\//)
          end
        end
      end
    end

    it "records an invalid_export failure for a malformed root (not a list)" do
      with_temp_dir do |base|
        archive = base / "malformed.zip"
        write_export(archive, JSON.parse(%({"not": "a list"})))
        with_chatgpt_runtime do |_store, graph, rt|
          result = Chronicle::Packs::ChatGPTExport.import_chatgpt_export_fn(graph, archive.to_s, "surface_bad")
          rt.run_until_idle
          result["ok"].as_bool.should be_false
          result["imported"].as_i.should eq(0)
          failures = graph.objects(type: "ingestion_failure")
          failures.size.should eq(1)
          JSON.parse(failures.first.data)["error_code"].as_s.should eq("invalid_export")
          graph.objects(type: "acquired_item").size.should eq(0)
        end
      end
    end

    it "fails closed on a non-existent archive" do
      with_chatgpt_runtime do |_store, graph, rt|
        result = Chronicle::Packs::ChatGPTExport.import_chatgpt_export_fn(
          graph, "/nonexistent/export.zip", "surface_bad",
        )
        rt.run_until_idle
        result["ok"].as_bool.should be_false
        failures = graph.objects(type: "ingestion_failure")
        failures.size.should eq(1)
        JSON.parse(failures.first.data)["error_code"].as_s.should eq("invalid_export")
      end
    end

    it "rejects unsupported replay modes and empty source_surface_id" do
      with_chatgpt_runtime do |_store, graph, _rt|
        expect_raises(Chronicle::Packs::PackError, /unsupported replay_mode/) do
          Chronicle::Packs::ChatGPTExport.import_chatgpt_export_fn(graph, "/tmp/x.zip", "s", replay_mode: "bogus")
        end
        expect_raises(Chronicle::Packs::PackError, /source_surface_id is required/) do
          Chronicle::Packs::ChatGPTExport.import_chatgpt_export_fn(graph, "/tmp/x.zip", "")
        end
      end
    end

    it "records invalid_conversation per malformed conversation, keeping valid siblings" do
      with_temp_dir do |base|
        archive = base / "mixed.zip"
        payload = JSON.parse(%([
          {"id": "good", "title": "Good", "current_node": "n1", "mapping": {
            "n1": {"id": "n1", "parent": null, "children": [], "message": {
              "id": "m1", "author": {"role": "user"}, "content": "hi"
            }}
          }},
          {"id": "bad", "title": "Bad", "current_node": "nope", "mapping": {
            "n1": {"id": "n1", "parent": null, "children": [], "message": {"id": "m1", "content": "x"}}
          }}
        ]))
        write_export(archive, payload)
        with_chatgpt_runtime do |_store, graph, rt|
          result = Chronicle::Packs::ChatGPTExport.import_chatgpt_export_fn(graph, archive.to_s, "surface_mixed")
          rt.run_until_idle
          result["ok"].as_bool.should be_false
          result["imported"].as_i.should eq(1)
          failures = graph.objects(type: "ingestion_failure")
          failures.size.should eq(1)
          JSON.parse(failures.first.data)["error_code"].as_s.should eq("invalid_conversation")
          items = graph.objects(type: "acquired_item")
          items.size.should eq(1)
          JSON.parse(items.first.data)["provider_item_id"].as_s.should eq("good:n1")
        end
      end
    end
  end
end

require "spec"
require "json"
require "file_utils"
require "compress/zip"
require "../spec_helper"

# Official Claude export importer (packs/importers/claude_export): bounded
# deterministic ingestion of official Claude data exports, accepting the
# export ZIP or a bare conversations.json snapshot. Translated from upstream
# packs/importers/claude_export/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# conversations.json is a flat list of conversations, each carrying an
# ordered chat_messages transcript — no branch tree. Every message becomes
# one acquired-item/content pair.

module ClaudeExportSpecSupport
  extend self

  def with_claude_runtime(artifact_store_dir : String = ".activegraph/replay-artifacts", &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifact_store_dir)
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(settings.to_json).as_h).should be_true
    settings_c = Chronicle::Packs::ClaudeExport::ClaudeExportSettings.new
    rt.load_pack(Chronicle::Packs::ClaudeExport.pack, JSON.parse(settings_c.to_json).as_h).should be_true
    yield store, graph, rt
  end

  def with_temp_dir(&)
    tmp = Path.new(Dir.tempdir) / "claude_#{Random::Secure.hex(6)}"
    FileUtils.mkdir_p(tmp)
    begin
      yield tmp
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  def message(uuid : String, sender : String, text : String, created_at : String) : Hash(String, JSON::Any)
    {
      "uuid"       => JSON::Any.new(uuid),
      "text"       => JSON::Any.new(text),
      "content"    => JSON::Any.new([JSON::Any.new({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)})]),
      "sender"     => JSON::Any.new(sender),
      "created_at" => JSON::Any.new(created_at),
      "updated_at" => JSON::Any.new(created_at),
    }
  end

  def flat_conversations : Array(Hash(String, JSON::Any))
    [
      {
        "uuid"          => JSON::Any.new("conversation-1"),
        "name"          => JSON::Any.new("Weekly planning"),
        "created_at"    => JSON::Any.new("2026-01-05T09:00:00.000000+00:00"),
        "updated_at"    => JSON::Any.new("2026-01-05T09:02:00.000000+00:00"),
        "chat_messages" => JSON::Any.new([
          JSON::Any.new(message("msg-1", "human", "Please draft the weekly plan.", "2026-01-05T09:00:00.000000+00:00")),
          JSON::Any.new(message("msg-2", "assistant", "Here is the weekly plan draft.", "2026-01-05T09:01:00.000000+00:00")),
        ]),
      },
      {
        "uuid"          => JSON::Any.new("conversation-2"),
        "name"          => JSON::Any.new("Tool use"),
        "created_at"    => JSON::Any.new("2026-01-06T10:00:00.000000+00:00"),
        "updated_at"    => JSON::Any.new("2026-01-06T10:01:00.000000+00:00"),
        "chat_messages" => JSON::Any.new([
          JSON::Any.new({
            "uuid"    => JSON::Any.new("msg-3"),
            "text"    => JSON::Any.new("Run the report."),
            "content" => JSON::Any.new([
              JSON::Any.new({"type" => JSON::Any.new("text"), "text" => JSON::Any.new("Run the report.")}),
              JSON::Any.new({"type" => JSON::Any.new("tool_use"), "name" => JSON::Any.new("report_runner")}),
            ]),
            "sender"     => JSON::Any.new("human"),
            "created_at" => JSON::Any.new("2026-01-06T10:00:00.000000+00:00"),
            "updated_at" => JSON::Any.new("2026-01-06T10:00:00.000000+00:00"),
          }),
        ]),
      },
    ]
  end

  def write_zip_export(path : Path, conversations : Array(Hash(String, JSON::Any)))
    payload = JSON::Any.new(conversations.map { |c| JSON::Any.new(c) })
    Compress::Zip::Writer.open(path) do |zip|
      zip.add("conversations.json", payload.to_json)
    end
  end
end

include ClaudeExportSpecSupport

describe Chronicle::Packs::ClaudeExport do
  describe "manifest-declared surface" do
    it "matches the upstream claude_export manifest" do
      pack = Chronicle::Packs::ClaudeExport.pack
      pack.name.should eq("claude_export")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq([] of String)
      pack.relation_types.map(&.name).should eq([] of String)
      pack.behaviors.map(&.name).should eq([] of String)
      pack.tools.map(&.name).should eq(["import_claude_export"])
      pack.settings_schema.should eq("ClaudeExportSettings")
    end

    it "declares settings with upstream defaults" do
      s = Chronicle::Packs::ClaudeExport::ClaudeExportSettings.new
      s.artifact_store_dir.should eq(".activegraph/replay-artifacts")
      s.replay_mode.should eq("artifact")
      s.max_archive_bytes.should eq(1_000_000_000)
      s.max_conversations_json_bytes.should eq(256_000_000)
      s.max_compression_ratio.should eq(200)
      s.max_conversations.should eq(10_000)
      s.max_messages_per_conversation.should eq(10_000)
      s.max_messages.should eq(250_000)
      s.max_normalized_chars.should eq(32_000)
    end
  end

  describe "import_claude_export_fn" do
    it "imports the official ZIP with correct counts and non-text omission" do
      with_temp_dir do |base|
        archive = base / "claude-export.zip"
        write_zip_export(archive, flat_conversations)
        store = base / "replay"
        with_claude_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          result = Chronicle::Packs::ClaudeExport.import_claude_export_fn(
            graph, archive.to_s, "surface_claude_fixture",
            artifact_store_dir: store.to_s, is_fixture: true,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_true
          result["imported"].as_i.should eq(3)
          result["conversations"].as_i.should eq(2)
          result["human_messages"].as_i.should eq(2)
          result["assistant_messages"].as_i.should eq(1)

          items = graph.objects(type: "acquired_item")
          items.map { |o| JSON.parse(o.data)["provider_item_id"].as_s }.sort.should eq(
            ["conversation-1:msg-1", "conversation-1:msg-2", "conversation-2:msg-3"]
          )
          contents = graph.objects(type: "acquired_content")
          contents.size.should eq(3)
          contents.each do |c|
            cd = JSON.parse(c.data)
            cd["source_category"].as_s.should eq("ai_activity")
            cd["connection_path"].as_s.should eq("export")
            cd["is_fixture"].as_bool.should be_true
          end
          omitted = contents.select { |c| JSON.parse(c.data)["normalized_content"].as_s.includes?("[tool_use content omitted]") }
          omitted.size.should eq(1)

          items.each do |item|
            idata = JSON.parse(item.data)
            digest = idata["replay_payload_hash"].as_s
            idata["replay_payload_ref"].as_s.should eq("artifact://sha256/#{digest[0, 2]}/#{digest}")
            File.exists?((store / "sha256" / digest[0, 2] / digest).to_s).should be_true
          end

          graph.objects(type: "activity_evidence").size.should eq(3)

          cursors = graph.objects(type: "backfill_cursor")
          cursors.size.should eq(1)
          cdata = JSON.parse(cursors.first.data)
          cdata["oldest_ingested_ref"].as_s.should eq("conversation-1:msg-1")
          cdata["newest_ingested_ref"].as_s.should eq("conversation-2:msg-3")
        end
      end
    end

    it "accepts a bare conversations.json snapshot" do
      with_temp_dir do |base|
        bare = base / "conversations.json"
        payload = JSON::Any.new(flat_conversations.map { |c| JSON::Any.new(c) })
        File.write(bare, payload.to_json)
        store = base / "replay"
        with_claude_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          result = Chronicle::Packs::ClaudeExport.import_claude_export_fn(
            graph, bare.to_s, "surface_claude_bare_fixture",
            artifact_store_dir: store.to_s, is_fixture: true,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_true
          result["imported"].as_i.should eq(3)
          items = graph.objects(type: "acquired_item")
          items.size.should eq(3)
          items.each { |o| JSON.parse(o.data)["source_ref"].as_s.should_not contain("!/") }
          graph.objects(type: "activity_evidence").size.should eq(3)
        end
      end
    end

    it "isolates a malformed conversation and keeps valid siblings" do
      with_temp_dir do |base|
        archive = base / "claude-export.zip"
        malformed = {
          "uuid"          => JSON::Any.new("conversation-bad"),
          "name"          => JSON::Any.new("Broken"),
          "chat_messages" => JSON::Any.new([
            JSON::Any.new({"text" => JSON::Any.new("message with no uuid"), "sender" => JSON::Any.new("human")}),
          ]),
        }
        write_zip_export(archive, [malformed] + flat_conversations.first(1))
        store = base / "replay"
        with_claude_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          result = Chronicle::Packs::ClaudeExport.import_claude_export_fn(
            graph, archive.to_s, "surface_claude_malformed_fixture",
            artifact_store_dir: store.to_s, is_fixture: true,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_false
          result["imported"].as_i.should eq(2)
          result["failed"].as_i.should eq(1)
          failures = graph.objects(type: "ingestion_failure")
          failures.size.should eq(1)
          fdata = JSON.parse(failures.first.data)
          fdata["stage"].as_s.should eq("acquisition")
          fdata["error_code"].as_s.should eq("invalid_conversation")
          fdata["metadata"].as_h["conversation_uuid"].as_s.should eq("conversation-bad")
          items = graph.objects(type: "acquired_item")
          items.map { |o| JSON.parse(o.data)["provider_item_id"].as_s }.sort.should eq(
            ["conversation-1:msg-1", "conversation-1:msg-2"]
          )
          graph.objects(type: "activity_evidence").size.should eq(2)
        end
      end
    end

    it "fails closed on a nonexistent export" do
      with_claude_runtime do |_store, graph, rt|
        result = Chronicle::Packs::ClaudeExport.import_claude_export_fn(
          graph, "/nonexistent/claude.json", "surface_bad",
        )
        rt.run_until_idle
        result["ok"].as_bool.should be_false
        failures = graph.objects(type: "ingestion_failure")
        failures.size.should eq(1)
        JSON.parse(failures.first.data)["error_code"].as_s.should eq("invalid_export")
      end
    end

    it "rejects unsupported replay modes and empty source_surface_id" do
      with_claude_runtime do |_store, graph, _rt|
        expect_raises(Chronicle::Packs::PackError, /unsupported replay_mode/) do
          Chronicle::Packs::ClaudeExport.import_claude_export_fn(graph, "/tmp/x.zip", "s", replay_mode: "bogus")
        end
        expect_raises(Chronicle::Packs::PackError, /source_surface_id is required/) do
          Chronicle::Packs::ClaudeExport.import_claude_export_fn(graph, "/tmp/x.zip", "")
        end
      end
    end

    it "maps sender human/assistant to role and records metadata" do
      with_temp_dir do |base|
        bare = base / "conversations.json"
        payload = JSON::Any.new(flat_conversations.map { |c| JSON::Any.new(c) })
        File.write(bare, payload.to_json)
        with_claude_runtime do |_store, graph, rt|
          Chronicle::Packs::ClaudeExport.import_claude_export_fn(graph, bare.to_s, "surface_meta", replay_mode: "inline")
          rt.run_until_idle
          contents = graph.objects(type: "acquired_content")
          msg1 = contents.find { |c| JSON.parse(c.data)["normalized_metadata"].as_h["message_uuid"]?.try(&.as_s?) == "msg-1" }
          msg1.should_not be_nil
          meta = JSON.parse(msg1.not_nil!.data)["normalized_metadata"].as_h
          meta["sender"].as_s.should eq("human")
          meta["role"].as_s.should eq("user")
          meta["conversation_uuid"].as_s.should eq("conversation-1")
          meta["content_source"].as_s.should eq("content_blocks")
          meta["message_index"].as_i.should eq(0)
        end
      end
    end
  end
end

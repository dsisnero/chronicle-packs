require "spec"
require "json"
require "file_utils"
require "../spec_helper"

# Assistant Local Sessions importer (packs/importers/assistant_local_sessions):
# bounded, deterministic ingestion of local agent-session JSONL logs (Claude
# Code projects/ and Codex sessions/ layouts), windowed to the most recent
# session files and parsed defensively against unversioned format drift.
# Translated from upstream packs/importers/assistant_local_sessions/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).

module AssistantLocalSessionsSpecSupport
  extend self

  def with_sessions_runtime(artifact_store_dir : String = ".activegraph/replay-artifacts", &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifact_store_dir)
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(settings.to_json).as_h).should be_true
    settings_s = Chronicle::Packs::AssistantLocalSessions::AssistantLocalSessionsSettings.new
    rt.load_pack(Chronicle::Packs::AssistantLocalSessions.pack, JSON.parse(settings_s.to_json).as_h).should be_true
    yield store, graph, rt
  end

  def with_temp_dir(&)
    tmp = Path.new(Dir.tempdir) / "sessions_#{Random::Secure.hex(6)}"
    FileUtils.mkdir_p(tmp)
    begin
      yield tmp
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  def write_jsonl(path : Path, lines : Array)
    FileUtils.mkdir_p(path.parent)
    rendered = lines.map do |line|
      line.is_a?(String) ? line : line.to_json
    end
    File.write(path, rendered.join("\n") + "\n")
  end

  def claude_line(role : String, content : JSON::Any, uuid : String, session_id : String, ts : String) : Hash(String, JSON::Any)
    {
      "type"      => JSON::Any.new(role),
      "message"   => JSON::Any.new({"role" => JSON::Any.new(role), "content" => content}),
      "uuid"      => JSON::Any.new(uuid),
      "timestamp" => JSON::Any.new(ts),
      "sessionId" => JSON::Any.new(session_id),
      "cwd"       => JSON::Any.new("/Users/casey/code/demo"),
    }
  end

  def claude_session_lines(session_id : String, base_ts : String) : Array
    [
      {"type" => "summary", "summary" => "Synthetic session summary", "leafUuid" => "u-x"},
      claude_line("user", JSON::Any.new("Please rename the widget module."), "#{session_id}-u1", session_id, base_ts),
      claude_line("assistant", JSON::Any.new([
        JSON::Any.new({"type" => JSON::Any.new("text"), "text" => JSON::Any.new("Renaming the widget module now.")}),
        JSON::Any.new({"type" => JSON::Any.new("tool_use"), "id" => JSON::Any.new("t1"), "name" => JSON::Any.new("Bash"), "input" => JSON::Any.new({"command" => JSON::Any.new("mv a b")})}),
      ]), "#{session_id}-a1", session_id, base_ts),
      claude_line("user", JSON::Any.new([JSON::Any.new({"type" => JSON::Any.new("tool_result"), "tool_use_id" => JSON::Any.new("t1"), "content" => JSON::Any.new("ok")})]), "#{session_id}-tr1", session_id, base_ts),
      "{this line is not JSON",
      {"type" => "system", "subtype" => "hook", "content" => "hook ran"},
      claude_line("assistant", JSON::Any.new([JSON::Any.new({"type" => JSON::Any.new("text"), "text" => JSON::Any.new("Done. The module was renamed.")})]), "#{session_id}-a2", session_id, base_ts),
    ]
  end

  def build_claude_tree(root : Path)
    project = root / "-Users-casey-code-demo"
    sessions = [
      {"sess-old", "2026-07-01T10:00:00.000Z", 1_000},
      {"sess-mid", "2026-07-02T10:00:00.000Z", 2_000},
      {"sess-new", "2026-07-03T10:00:00.000Z", 3_000},
    ]
    sessions.each do |session_id, ts, mtime|
      path = project / "#{session_id}.jsonl"
      write_jsonl(path, claude_session_lines(session_id, ts))
      File.utime(Time.unix(mtime), Time.unix(mtime), path)
    end
  end

  def codex_response(role : String, part_type : String, text : String, ts : String) : Hash(String, JSON::Any)
    {
      "type"      => JSON::Any.new("response_item"),
      "timestamp" => JSON::Any.new(ts),
      "payload"   => JSON::Any.new({
        "type"    => JSON::Any.new("message"),
        "role"    => JSON::Any.new(role),
        "content" => JSON::Any.new([JSON::Any.new({"type" => JSON::Any.new(part_type), "text" => JSON::Any.new(text)})]),
      }),
    }
  end

  def codex_session_lines(session_id : String, ts : String) : Array
    [
      {"type" => "session_meta", "timestamp" => ts, "payload" => {"id" => session_id, "cwd" => "/Users/casey/code/demo", "cli_version" => "9.9.9"}},
      codex_response("developer", "input_text", "You are a synthetic system prompt.", ts),
      codex_response("user", "input_text", "Summarize the release notes.", ts),
      {"type" => "event_msg", "timestamp" => ts, "payload" => {"type" => "token_count", "total" => 12}},
      codex_response("assistant", "output_text", "The release adds a bounded importer.", ts),
      "%% malformed line %%",
      {"type" => "message", "role" => "user", "timestamp" => ts, "content" => [{"type" => "input_text", "text" => "Older flat variant line."}]},
    ]
  end

  def build_codex_tree(root : Path)
    days = [
      {"2026/07/01", "rollout-2026-07-01T09-00-00-aaaa1111", "codex-old", "2026-07-01T09:00:00Z"},
      {"2026/07/02", "rollout-2026-07-02T09-00-00-bbbb2222", "codex-mid", "2026-07-02T09:00:00Z"},
      {"2026/07/03", "rollout-2026-07-03T09-00-00-cccc3333", "codex-new", "2026-07-03T09:00:00Z"},
    ]
    days.each do |day, stem, session_id, ts|
      write_jsonl(root / day / "#{stem}.jsonl", codex_session_lines(session_id, ts))
    end
  end
end

include AssistantLocalSessionsSpecSupport

describe Chronicle::Packs::AssistantLocalSessions do
  describe "manifest-declared surface" do
    it "matches the upstream assistant_local_sessions manifest" do
      pack = Chronicle::Packs::AssistantLocalSessions.pack
      pack.name.should eq("assistant_local_sessions")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq([] of String)
      pack.relation_types.map(&.name).should eq([] of String)
      pack.behaviors.map(&.name).should eq([] of String)
      pack.tools.map(&.name).should eq(["import_assistant_local_sessions"])
      pack.settings_schema.should eq("AssistantLocalSessionsSettings")
    end

    it "declares settings with upstream defaults" do
      s = Chronicle::Packs::AssistantLocalSessions::AssistantLocalSessionsSettings.new
      s.claude_code_root_path.should eq("~/.claude/projects")
      s.codex_root_path.should eq("~/.codex/sessions")
      s.artifact_store_dir.should eq(".activegraph/replay-artifacts")
      s.replay_mode.should eq("artifact")
      s.max_sessions.should eq(20)
      s.max_file_bytes.should eq(50_000_000)
      s.max_lines_per_file.should eq(100_000)
      s.max_messages.should eq(25_000)
      s.max_normalized_chars.should eq(16_000)
    end
  end

  describe "import_assistant_local_sessions_fn" do
    it "imports a bounded Claude Code window: 2 newest of 3 sessions, lines skip cleanly" do
      with_temp_dir do |base|
        root = base / "claude-projects"
        build_claude_tree(root)
        store = base / "replay-claude"
        with_sessions_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          result = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
            graph, root.to_s, "surface_claude_fixture",
            provider: "claude_code", artifact_store_dir: store.to_s,
            max_sessions: 2, is_fixture: true,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_true
          result["imported"].as_i.should eq(6)
          result["sessions_imported"].as_i.should eq(2)
          result["malformed_lines"].as_i.should eq(2)
          result["skipped_lines"].as_i.should be >= 4
          window = result["window"].as_h
          window["files_considered"].as_i.should eq(3)
          window["files_skipped_by_window"].as_i.should eq(1)
          window["order_key"].as_s.should eq("file_mtime_then_name")
          window["files_imported"].as_a.map(&.as_s).sort.should eq(
            ["-Users-casey-code-demo/sess-mid.jsonl", "-Users-casey-code-demo/sess-new.jsonl"]
          )

          items = graph.objects(type: "acquired_item")
          items.size.should eq(6)
          keys = items.map { |o| JSON.parse(o.data)["dedup_key"].as_s }.to_set
          keys.should contain("sess-new:sess-new-u1")
          items.each do |item|
            idata = JSON.parse(item.data)
            idata["media_type"].as_s.should eq("application/json")
            idata["replay_payload_ref"].as_s.should match(/^artifact:\/\/sha256\//)
          end
          contents = graph.objects(type: "acquired_content")
          contents.each do |c|
            cd = JSON.parse(c.data)
            cd["source_category"].as_s.should eq("ai_activity")
            cd["connection_path"].as_s.should eq("local")
            cd["is_fixture"].as_bool.should be_true
          end
          graph.objects(type: "activity_evidence").size.should eq(6)
          cursors = graph.objects(type: "backfill_cursor")
          cursors.size.should eq(1)
          cdata = JSON.parse(cursors.first.data)
          cdata["oldest_ingested_ref"].as_s.should eq("-Users-casey-code-demo/sess-mid.jsonl")
          cdata["newest_ingested_ref"].as_s.should eq("-Users-casey-code-demo/sess-new.jsonl")
        end
      end
    end

    it "parses Codex nested + flat variants defensively, skipping developer/system lines" do
      with_temp_dir do |base|
        root = base / "codex-sessions"
        build_codex_tree(root)
        store = base / "replay-codex"
        with_sessions_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          result = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
            graph, root.to_s, "surface_codex_fixture",
            provider: "codex", artifact_store_dir: store.to_s,
            max_sessions: 2, is_fixture: true,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_true
          result["imported"].as_i.should eq(6)
          result["malformed_lines"].as_i.should eq(2)
          window = result["window"].as_h
          window["files_considered"].as_i.should eq(3)
          window["files_skipped_by_window"].as_i.should eq(1)
          window["order_key"].as_s.should eq("filename_timestamp")

          items = graph.objects(type: "acquired_item")
          keys = items.map { |o| JSON.parse(o.data)["dedup_key"].as_s }.sort
          keys.should contain("codex-new:line-3")
          keys.should contain("codex-new:line-5")
          keys.should contain("codex-new:line-7")
          items.each { |o| JSON.parse(o.data)["provider_time"].as_s?.should_not be_nil }
          graph.objects(type: "activity_evidence").size.should eq(6)
          roles = graph.objects(type: "activity_evidence").map do |e|
            JSON.parse(e.data)["normalized_metadata"].as_h["role"].as_s
          end.to_set
          roles.should eq(Set{"user", "assistant"})
        end
      end
    end

    it "records a recoverable unreadable_file failure while siblings commit" do
      with_temp_dir do |base|
        root = base / "claude-broken"
        project = root / "-Users-casey-code-demo"
        good = project / "sess-good.jsonl"
        write_jsonl(good, claude_session_lines("sess-good", "2026-07-03T10:00:00.000Z"))
        bad = project / "sess-bad.jsonl"
        File.write(bad, Bytes[0xFF, 0xFE, 0x00, 0x20])
        store = base / "replay-broken"
        with_sessions_runtime(artifact_store_dir: store.to_s) do |_store, graph, rt|
          result = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
            graph, root.to_s, "surface_broken_fixture",
            provider: "claude_code", artifact_store_dir: store.to_s, is_fixture: true,
          )
          rt.run_until_idle
          result["ok"].as_bool.should be_false
          result["imported"].as_i.should eq(3)
          result["failed"].as_i.should eq(1)
          result["window"].as_h["files_failed"].as_a.map(&.as_s).should eq(["-Users-casey-code-demo/sess-bad.jsonl"])
          failures = graph.objects(type: "ingestion_failure")
          acquisition = failures.select { |f| JSON.parse(f.data)["error_code"].as_s == "unreadable_file" }
          acquisition.size.should eq(1)
          JSON.parse(acquisition.first.data)["stage"].as_s.should eq("acquisition")
          JSON.parse(acquisition.first.data)["recoverable"].as_bool.should be_true
          graph.objects(type: "activity_evidence").size.should eq(3)
        end
      end
    end

    it "keeps evidence stable on reimport and adds only an appended message" do
      with_temp_dir do |base|
        root = base / "claude-reimport"
        build_claude_tree(root)
        store = base / "replay-reimport"
        with_sessions_runtime(artifact_store_dir: store.to_s) do |_store, graph, runtime|
          import_once = -> {
            result = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
              graph, root.to_s, "surface_reimport", provider: "claude_code",
              artifact_store_dir: store.to_s, is_fixture: true,
            )
            runtime.run_until_idle
            result
          }

          import_once.call["imported"].as_i.should eq(9)
          graph.objects(type: "activity_evidence").size.should eq(9)
          import_once.call["imported"].as_i.should eq(9)
          evidence = graph.objects(type: "activity_evidence")
          evidence.size.should eq(9)
          evidence.each { |item| JSON.parse(item.data)["revision_number"].as_i.should eq(1) }

          appended = claude_line("assistant", JSON::Any.new("A brand new appended reply."), "sess-new-a9", "sess-new", "2026-07-04T10:00:00.000Z")
          target = root / "-Users-casey-code-demo" / "sess-new.jsonl"
          File.open(target, "a") { |file| file.puts(appended.to_json) }
          File.utime(Time.unix(4_000), Time.unix(4_000), target)

          import_once.call["imported"].as_i.should eq(10)
          evidence = graph.objects(type: "activity_evidence")
          evidence.size.should eq(10)
          appended_evidence = evidence.select { |item| JSON.parse(item.data)["dedup_key"].as_s == "sess-new:sess-new-a9" }
          appended_evidence.size.should eq(1)
          JSON.parse(appended_evidence.first.data)["normalized_content"].as_s.should eq("A brand new appended reply.")
        end
      end
    end

    it "retains a canonical replay artifact for each imported message" do
      with_temp_dir do |base|
        root = base / "claude-replay"
        line = claude_line("user", JSON::Any.new("Verify replay please."), "u-replay", "sess-replay", "2026-07-03T10:00:00Z")
        write_jsonl(root / "-Users-casey-code-demo" / "sess-replay.jsonl", [line])
        store = base / "replay-artifacts"
        with_sessions_runtime(artifact_store_dir: store.to_s) do |_store, graph, _runtime|
          result = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
            graph, root.to_s, "surface_replay", provider: "claude_code", artifact_store_dir: store.to_s)
          result["imported"].as_i.should eq(1)

          item = JSON.parse(graph.objects(type: "acquired_item").first.data)
          digest = item["replay_payload_hash"].as_s
          item["replay_mode"].as_s.should eq("artifact")
          item["replay_payload_ref"].as_s.should eq("artifact://sha256/#{digest[0, 2]}/#{digest}")
          artifact = store / "sha256" / digest[0, 2] / digest
          File.file?(artifact).should be_true
          payload = File.read(artifact)
          Digest::SHA256.hexdigest(payload).should eq(digest)
          unit = JSON.parse(payload)
          unit["provider"].as_s.should eq("claude_code")
          unit["session_id"].as_s.should eq("sess-replay")
          unit["message_uuid"].as_s.should eq("u-replay")
          unit["role"].as_s.should eq("user")
          unit["line_number"].as_i.should eq(1)
          unit["normalized_content"].as_s.should eq("Verify replay please.")
          Chronicle::Packs::AssistantLocalSessions._canonical_json(unit).should eq(payload)
        end
      end
    end

    it "propagates the fixture flag and honors explicit session-window extension" do
      with_temp_dir do |base|
        root = base / "claude-window"
        build_claude_tree(root)
        store = base / "replay-window"
        with_sessions_runtime(artifact_store_dir: store.to_s) do |_store, graph, runtime|
          narrow = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
            graph, root.to_s, "surface_window", provider: "claude_code", artifact_store_dir: store.to_s,
            max_sessions: 1, is_fixture: true,
          )
          narrow["imported"].as_i.should eq(3)
          narrow["window"].as_h["files_skipped_by_window"].as_i.should eq(2)
          runtime.run_until_idle
          JSON.parse(graph.objects(type: "acquired_content").first.data)["is_fixture"].as_bool.should be_true
          JSON.parse(graph.objects(type: "activity_evidence").first.data)["is_fixture"].as_bool.should be_true

          _wide_store, wide_graph, wide_runtime = PackSpecRuntime.runtime
          wide_runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
          normalizer = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: store.to_s)
          wide_runtime.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(normalizer.to_json).as_h).should be_true
          wide_runtime.load_pack(Chronicle::Packs::AssistantLocalSessions.pack).should be_true
          wide = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
            wide_graph, root.to_s, "surface_window_wide", provider: "claude_code", artifact_store_dir: store.to_s,
            max_sessions: 10,
          )
          wide["imported"].as_i.should eq(9)
          wide["window"].as_h["files_skipped_by_window"].as_i.should eq(0)
        end
      end
    end

    it "fails closed on an invalid root" do
      with_sessions_runtime do |_store, graph, rt|
        result = Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(
          graph, "/nonexistent/sessions", "surface_bad",
        )
        rt.run_until_idle
        result["ok"].as_bool.should be_false
        failures = graph.objects(type: "ingestion_failure")
        failures.size.should eq(1)
        JSON.parse(failures.first.data)["error_code"].as_s.should eq("invalid_root")
      end
    end

    it "rejects unsupported providers, replay modes, and empty source_surface_id" do
      with_sessions_runtime do |_store, graph, _rt|
        expect_raises(Chronicle::Packs::PackError, /unsupported provider/) do
          Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(graph, "/tmp", "s", provider: "bogus")
        end
        expect_raises(Chronicle::Packs::PackError, /unsupported replay_mode/) do
          Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(graph, "/tmp", "s", replay_mode: "bogus")
        end
        expect_raises(Chronicle::Packs::PackError, /source_surface_id is required/) do
          Chronicle::Packs::AssistantLocalSessions.import_assistant_local_sessions_fn(graph, "/tmp", "")
        end
      end
    end
  end
end

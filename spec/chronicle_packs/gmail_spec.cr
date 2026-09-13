require "spec"
require "json"
require "set"
require "file_utils"
require "../spec_helper"

# Gmail Pack (packs/gmail): canonical Gmail service connector — budgeted
# exploration into a service/account profile, bounded replayable backfill,
# history-watermark polling, provider-neutral evidence, local conversation
# family mapping with deterministic hygiene, local draft candidates,
# reversible draft writes, and R3-forever sends through an injected route
# adapter (Composio first). Translated from upstream packs/gmail/*
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# The fixture transport mirrors upstream tests/test_gmail_connector.py
# FakeComposio so the whole cascade (core + activity_normalizer +
# semantic_extraction + entity + communication + usage + connector_control +
# tool_gateway + composio + gmail) runs offline: no token, no network.

# A provider message shaped like the Gmail API wire format.
def gmail_fixture_message(mid : String, subject : String, body : String, history : String) : Hash(String, JSON::Any)
  {
    "id"        => JSON::Any.new(mid),
    "threadId"  => JSON::Any.new("thread-#{mid}"),
    "historyId" => JSON::Any.new(history),
    "labelIds"  => JSON::Any.new([JSON::Any.new("INBOX")]),
    "payload"   => JSON::Any.new({
      "headers" => JSON::Any.new([
        JSON::Any.new({"name" => JSON::Any.new("Subject"), "value" => JSON::Any.new(subject)}),
        JSON::Any.new({"name" => JSON::Any.new("From"), "value" => JSON::Any.new("founder@example.com")}),
        JSON::Any.new({"name" => JSON::Any.new("To"), "value" => JSON::Any.new("yohei@example.com")}),
        JSON::Any.new({"name" => JSON::Any.new("Date"), "value" => JSON::Any.new("2026-07-10T10:00:00+00:00")}),
        JSON::Any.new({"name" => JSON::Any.new("Message-ID"), "value" => JSON::Any.new("<#{mid}@example.com>")}),
      ]),
    }),
    "messageText" => JSON::Any.new(body),
  } of String => JSON::Any
end

# The offline Composio route adapter (mirrors FakeComposio).
class GmailFixtureComposio < Chronicle::Packs::Composio::ComposioTransport
  getter calls = [] of {String, Hash(String, JSON::Any)}
  property fail_next_fetch = false
  property bad_shape_next_fetch = false
  property rate_limit_next_history = false
  property invalid_cursor_next_history = false
  property missing_history_message = false

  def authorize(*, user_id : String, toolkit : String, callback_url : String) : Hash(String, JSON::Any)
    {"id" => JSON::Any.new("link_1"), "redirect_url" => JSON::Any.new("https://connect.composio.dev/link/secret-token"), "status" => JSON::Any.new("INITIATED")} of String => JSON::Any
  end

  def list_connections(*, user_id : String, toolkit : String, limit : Int32) : Array(Hash(String, JSON::Any))
    [{"id" => JSON::Any.new("ca_1"), "status" => JSON::Any.new("ACTIVE"), "toolkit_slug" => JSON::Any.new("gmail")} of String => JSON::Any]
  end

  def resolve_tool(*, toolkit : String, candidates : Array(String), requested_version : String) : Hash(String, JSON::Any)
    rows = candidates.map do |slug|
      {
        "slug"               => JSON::Any.new(slug),
        "toolkit"            => JSON::Any.new({"slug" => JSON::Any.new(toolkit)}),
        "version"            => JSON::Any.new("20260702_01"),
        "available_versions" => JSON::Any.new([JSON::Any.new("20260702_01")]),
        "input_parameters"   => JSON::Any.new({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new({} of String => JSON::Any)}),
        "is_deprecated"      => JSON::Any.new(false),
      } of String => JSON::Any
    end
    Chronicle::Packs::Composio.resolve_catalog_tool(rows, toolkit: toolkit, candidates: candidates, requested_version: requested_version)
  end

  def execute(*, tool_slug : String, arguments : Hash(String, JSON::Any), user_id : String, connected_account_id : String, version : String) : Hash(String, JSON::Any)
    @calls << {tool_slug, {"version" => JSON::Any.new(version), "arguments" => JSON::Any.new(arguments)} of String => JSON::Any}
    data =
      case tool_slug
      when "GMAIL_GET_PROFILE"
        {"emailAddress" => JSON::Any.new("yohei@example.com"), "messagesTotal" => JSON::Any.new(3), "threadsTotal" => JSON::Any.new(3), "historyId" => JSON::Any.new("900")} of String => JSON::Any
      when "GMAIL_LIST_LABELS"
        {"labels" => JSON::Any.new([JSON::Any.new({"id" => JSON::Any.new("INBOX"), "name" => JSON::Any.new("INBOX"), "type" => JSON::Any.new("system")})])} of String => JSON::Any
      when "GMAIL_FETCH_EMAILS"
        if @fail_next_fetch
          @fail_next_fetch = false
          return {"successful" => JSON::Any.new(false), "error" => JSON::Any.new("temporary upstream failure"), "data" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
        end
        if @bad_shape_next_fetch
          @bad_shape_next_fetch = false
          {"unexpected" => JSON::Any.new({"mail" => JSON::Any.new("moved")})} of String => JSON::Any
        elsif arguments["page_token"]? == "page-2"
          {"messages" => JSON::Any.new([JSON::Any.new(gmail_fixture_message("m2", "Second", "follow up", "900"))])} of String => JSON::Any
        else
          {"messages" => JSON::Any.new([JSON::Any.new(gmail_fixture_message("m1", "First", "hello", "899"))]), "nextPageToken" => JSON::Any.new("page-2")} of String => JSON::Any
        end
      when "GMAIL_LIST_HISTORY"
        if @rate_limit_next_history
          @rate_limit_next_history = false
          return {"successful" => JSON::Any.new(false), "error" => JSON::Any.new("429 rate limit exceeded"), "data" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
        end
        if @invalid_cursor_next_history
          @invalid_cursor_next_history = false
          return {"successful" => JSON::Any.new(false), "error" => JSON::Any.new("404 historyId is too old"), "data" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
        end
        added = [{"message" => JSON::Any.new({"id" => JSON::Any.new("m3")})} of String => JSON::Any]
        if @missing_history_message
          added.insert(0, {"message" => JSON::Any.new({"id" => JSON::Any.new("m-gone")})} of String => JSON::Any)
        end
        {
          "history" => JSON::Any.new([
            JSON::Any.new({
              "messagesAdded"   => JSON::Any.new(added.map { |row| JSON::Any.new(row) }),
              "messagesDeleted" => JSON::Any.new([JSON::Any.new({"message" => JSON::Any.new({"id" => JSON::Any.new("m1")})})]),
            } of String => JSON::Any),
          ]),
          "historyId" => JSON::Any.new("901"),
        } of String => JSON::Any
      when "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID"
        if arguments["message_id"]? == "m-gone"
          return {"successful" => JSON::Any.new(false), "error" => JSON::Any.new("404 Requested entity was not found"), "data" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
        end
        gmail_fixture_message("m3", "Third", "new mail", "901")
      else
        {"id" => JSON::Any.new("provider-result")} of String => JSON::Any
      end
    {"successful" => JSON::Any.new(true), "data" => JSON::Any.new({"response_data" => JSON::Any.new(data)}), "error" => JSON::Any.new(nil)} of String => JSON::Any
  end
end

module GmailSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  ARTIFACT_DIR = begin
    path = Path[__DIR__].parent.parent / "tmp" / "gmail_replay_artifact_test"
    FileUtils.rm_rf(path)
    FileUtils.mkdir_p(path)
    path.to_s
  end

  def artifact_dir : String
    ARTIFACT_DIR
  end

  def gmail_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "gmail" / "manifest.toml"
  end

  # The cross-pack cascade the upstream fixtures use (core + normalizer +
  # extraction + entity + communication + usage + connector_control + gateway
  # + composio + gmail), with the fixture transport configured and the
  # canonical Gmail capabilities registered. Mirrors test_gmail_connector.py
  # _runtime().
  def with_gmail_runtime(fake : GmailFixtureComposio? = nil, settings : Chronicle::Packs::Gmail::GmailSettings? = nil, &)
    transport = fake || GmailFixtureComposio.new
    store, graph, rt = PackSpecRuntime.runtime
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::Composio.configure_composio_transport(transport)

    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    normalizer_settings = Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(artifact_store_dir: artifact_dir)
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, JSON.parse(normalizer_settings.to_json).as_h).should be_true
    rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    rt.load_pack(Chronicle::Packs::Entity.pack).should be_true
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    rt.load_pack(Chronicle::Packs::Usage.pack).should be_true
    rt.load_pack(Chronicle::Packs::ConnectorControl.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    rt.load_pack(Chronicle::Packs::Composio.pack).should be_true
    gmail_settings = settings || Chronicle::Packs::Gmail::GmailSettings.new(artifact_store_dir: artifact_dir)
    rt.load_pack(Chronicle::Packs::Gmail.pack, JSON.parse(gmail_settings.to_json).as_h).should be_true
    Chronicle::Packs::Composio.register_composio_capabilities
    Chronicle::Packs::Gmail.register_gmail_capabilities(artifact_store_dir: artifact_dir)
    Chronicle::Packs::Gmail.register_gmail_maintenance

    yield store, graph, rt, transport
  ensure
    Chronicle::Packs::Composio.configure_composio_transport(nil)
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::ConnectorControl.clear_connector_maintenance_handlers
  end

  def surface_for(graph : Chronicle::GraphProjection) : Chronicle::GraphObject
    graph.objects(type: "connection_surface").first.not_nil!
  end

  def object_data(obj : Chronicle::GraphObject) : Hash(String, JSON::Any)
    JSON.parse(obj.data).as_h
  end
end

include GmailSpecSupport

describe Chronicle::Packs::Gmail do
  describe "manifest-declared surface" do
    it "matches the upstream gmail manifest" do
      pack = Chronicle::Packs::Gmail.pack
      pack.name.should eq("gmail")
      pack.version.should eq("0.3.0")
      pack.object_types.map(&.name).should eq(["gmail_sync_run", "gmail_draft_candidate"])
      pack.relation_types.map(&.name).should eq(["gmail_sync_call", "gmail_draft_call"])
      pack.behaviors.map(&.name).should eq([
        "gmail_exploration_projector",
        "gmail_sync_result_ingester",
        "gmail_draft_result_projector",
        "gmail_control_plane_adapter",
        "gmail_control_plane_run_created",
        "gmail_conversation_family_ready",
        "gmail_conversation_batch_projector",
        "gmail_control_plane_learning_settled",
        "gmail_control_plane_failure",
      ])
      pack.tools.map(&.name).should eq([
        "request_gmail_exploration",
        "request_gmail_backfill",
        "request_gmail_poll",
        "create_gmail_draft_candidate",
        "request_gmail_draft_sync",
        "request_gmail_draft_send",
        "reprocess_gmail_evidence",
      ])
      pack.settings_schema.should eq("GmailSettings")
      pack.capabilities.map(&.capability).should eq([
        "drafts.create", "drafts.send", "history.list", "labels.list",
        "messages.fetch", "messages.get", "profile.get",
      ])
      pack.capabilities.map(&.risk_class).should eq(["medium", "high", "low", "low", "low", "low", "low"])
      pack.capabilities.map(&.action_class).should eq(["R2", "R3", "R0", "R0", "R0", "R0", "R0"])
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(gmail_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Gmail.pack)
    end

    it "round-trips the closed Gmail string sets through the underscore enum names" do
      JSON.parse(Chronicle::Packs::Gmail::SyncMode::Backfill.to_json).as_s.should eq("backfill")
      JSON.parse(Chronicle::Packs::Gmail::SyncMode::Poll.to_json).as_s.should eq("poll")
      JSON.parse(Chronicle::Packs::Gmail::SyncStatus::Partial.to_json).as_s.should eq("partial")
      JSON.parse(Chronicle::Packs::Gmail::DraftStatus::SyncProposed.to_json).as_s.should eq("sync_proposed")
      JSON.parse(Chronicle::Packs::Gmail::ErrorCode::CursorInvalid.to_json).as_s.should eq("cursor_invalid")
    end

    it "resolves the latest Gmail catalog entry and rejects an unavailable pin" do
      rows = [{
        "slug"               => JSON::Any.new("GMAIL_GET_PROFILE"),
        "toolkit"            => JSON::Any.new({"slug" => JSON::Any.new("gmail")} of String => JSON::Any),
        "version"            => JSON::Any.new("20260702_01"),
        "available_versions" => JSON::Any.new([JSON::Any.new("20260702_01")]),
        "input_parameters"   => JSON::Any.new({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new({"user_id" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)} of String => JSON::Any)} of String => JSON::Any),
        "is_deprecated"      => JSON::Any.new(false),
      } of String => JSON::Any]

      resolved = Chronicle::Packs::Composio.resolve_catalog_tool(rows, toolkit: "gmail", candidates: ["GMAIL_GET_PROFILE_V2", "GMAIL_GET_PROFILE"], requested_version: "latest")
      resolved["tool_slug"].as_s.should eq("GMAIL_GET_PROFILE")
      resolved["version"].as_s.should eq("20260702_01")
      resolved["resolution"].as_s.should eq("catalog")
      resolved["input_schema_fingerprint"].as_s.should_not be_empty

      expect_raises(Chronicle::Packs::Composio::ComposioUnavailable, /available versions: 20260702_01/) do
        Chronicle::Packs::Composio.resolve_catalog_tool(rows, toolkit: "gmail", candidates: ["GMAIL_GET_PROFILE"], requested_version: "20260703_00")
      end
    end
  end

  describe "connection authorization" do
    it "governs a Gmail connect link and excludes its secret from durable records" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        call = Chronicle::Packs::Composio.request_composio_link_fn(
          graph,
          user_id: "agent:owner",
          service: "gmail",
          callback_url: "http://127.0.0.1/callback",
        )
        rt.run_until_idle
        object_data(graph.get_object(call.id).not_nil!)["status"].as_s.should eq("policy_checking")

        Chronicle::Packs::ToolGateway.approve_capability_fn(graph, call.id, approver_ref: "owner:client")["ok"].as_bool.should be_true
        rt.run_until_idle

        result = graph.objects(type: "capability_result").find { |obj| object_data(obj)["call_id"].as_s == call.id }.not_nil!
        output = object_data(result)["output_data"].as_s
        output.should contain("connect.composio.dev")
        output.should_not contain("secret-token")
        Chronicle::Packs::Composio.take_redirect("link_1").should eq("https://connect.composio.dev/link/secret-token")
        graph.events.map(&.payload).join("\n").should_not contain("secret-token")
      end
    end
  end

  describe "exploration" do
    it "proposes two R0 probes and projects an active profile, surface, and watermark cursor" do
      with_gmail_runtime do |_store, graph, rt, fake|
        exploration = Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        exploration["created"].as_bool.should be_true
        exploration["call_ids"].as_a.size.should eq(2)
        rt.run_until_idle

        profile = graph.objects(type: "integration_profile").find { |obj| object_data(obj)["status"].as_s == "active" }
        profile.should_not be_nil
        pd = object_data(profile.not_nil!)
        pd["service"].as_s.should eq("gmail")
        pd["account_ref"].as_s.should eq("yohei@example.com")
        pd["routes"].as_a.first.as_h["schema_version"].as_s.should eq("20260702_01")
        pd["routes"].as_a.first.as_h["path"].as_s.should eq("composio")
        pd["capability_inventory"].as_a.map { |row| row.as_h["operation"].as_s }.should contain("gmail.messages.fetch")
        pd["capability_inventory"].as_a.map { |row| row.as_h["operation"].as_s }.should contain("gmail.drafts.send")
        pd["claims"].as_a.map { |row| row.as_h["claim_key"].as_s }.should contain("account.identity")
        pd["claims"].as_a.map { |row| row.as_h["claim_key"].as_s }.should contain("mailbox.label_topology")
        pd["claims"].as_a.map { |row| row.as_h["claim_key"].as_s }.should contain("signal.inbox_richness")

        surface = surface_for(graph)
        sd = object_data(surface)
        sd["path"].as_s.should eq("composio")
        sd["category"].as_s.should eq("communication")
        graph.events.any? { |e| e.type == "source.connected" && (JSON.parse(e.payload).as_h["surface_id"]?.try(&.as_s?) == sd["surface_id"].as_s) }.should be_true

        cursor = graph.objects(type: "backfill_cursor")
        cursor.size.should eq(1)
        object_data(cursor.first)["watermark_ref"].as_s.should eq("history:900")

        probes = fake.calls.select { |name, _args| name.in?({"GMAIL_GET_PROFILE", "GMAIL_LIST_LABELS"}) }
        probes.size.should eq(2)
        probes.map { |_name, args| args["version"]?.try(&.as_s) }.should eq(["20260702_01", "20260702_01"])
        rt.errors.should be_empty
      end
    end

    it "does not rediscover the same account into duplicate profiles" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        repeat = Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle

        repeat["created"].as_bool.should be_false
        graph.objects(type: "integration_profile").size.should eq(1)
        graph.objects(type: "connection_surface").size.should eq(1)
      end
    end

    it "supersedes a Gmail-discovered claim with an owner correction" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        profile = graph.objects(type: "integration_profile").find { |obj| object_data(obj)["status"].as_s == "active" }.not_nil!

        corrected = Chronicle::Packs::ToolGateway.correct_integration_claim_fn(
          graph,
          profile_id: profile.id,
          claim_key: "signal.inbox_richness",
          value: JSON::Any.new("medium"),
          actor: "owner:test",
          reason: "this account is mostly receipts",
        )
        current = graph.get_object(corrected["profile_id"].as_s).not_nil!
        claim = object_data(current)["claims"].as_a.find { |row| row.as_h["claim_key"].as_s == "signal.inbox_richness" }.not_nil!.as_h
        object_data(graph.get_object(profile.id).not_nil!)["status"].as_s.should eq("superseded")
        object_data(current)["profile_version"].as_i.should eq(2)
        claim["classification_source"].as_s.should eq("operator")
        claim["value"].as_s.should eq("medium")
        claim["metadata"].as_h["reason"].as_s.should eq("this account is mostly receipts")
      end
    end
  end

  describe "backfill" do
    it "imports bounded evidence, reprocesses locally, and projects the control plane" do
      with_gmail_runtime do |_store, graph, rt, fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)

        run = Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          query: "newer_than:30d",
          page_size: 1,
          max_messages: 2,
          max_pages: 2,
        )
        rt.run_until_idle

        run_obj = graph.get_object(run["run_id"].as_s).not_nil!
        object_data(run_obj)["status"].as_s.should eq("completed")
        evidence = graph.objects(type: "activity_evidence")
        evidence.size.should eq(2)
        evidence.each do |obj|
          ed = object_data(obj)
          ed["connection_path"].as_s.should eq("composio")
          ed["replay_mode"].as_s.should eq("artifact")
        end

        calls_before = fake.calls.size
        interpretation_before = graph.objects(type: "conversation_interpretation_run").size
        replayed = Chronicle::Packs::Gmail.reprocess_gmail_evidence_fn(graph, source_surface_id: object_data(surface)["surface_id"].as_s)
        rt.run_until_idle
        replayed["provider_contacted"].as_bool.should be_false
        replayed["messages_reprocessed"].as_i.should eq(2)
        fake.calls.size.should eq(calls_before)
        runs_after = graph.objects(type: "conversation_interpretation_run")
        runs_after.size.should eq(interpretation_before + 2)
        runs_after.count { |obj| !object_data(obj)["reprocess_of"]?.try(&.as_s?).nil? }.should eq(2)

        control = Chronicle::Packs::ConnectorControl.project_connector_control_plane_fn(graph)
        binding = control["bindings"].as_a.first.as_h
        binding["family"].as_s.should eq("conversation")
        binding["active_route"].as_s.should eq("composio")
        backfill_row = control["runs"].as_a.find { |row| row.as_h["domain_run_id"]?.try(&.as_s?) == run["run_id"].as_s }.not_nil!.as_h
        backfill_row["state"].as_s.should eq("succeeded")
        backfill_row["health"].as_s.should eq("current")
        backfill_row["counts"].as_h["imported"].as_i.should eq(2)
        backfill_row["manual_refresh_available"].as_bool.should be_true

        native = control["native_views"].as_a.first.as_h
        native["family"].as_s.should eq("conversation")
        native["state"].as_s.should eq("ready")
        native["data"].as_h["total_count"].as_i.should eq(2)
        native["data"].as_h["threads"].as_a.map { |row| row.as_h["title"].as_s }.to_set.should eq(Set{"First", "Second"})

        graph.objects(type: "conversation_message").size.should eq(2)
        graph.objects(type: "conversation_thread").size.should eq(2)
        graph.objects(type: "entity_mention").size.should eq(2)
        graph.objects(type: "entity").size.should eq(2)

        delta = Chronicle::Packs::ConnectorControl.project_connector_learning_deltas_fn(graph)["deltas"].as_a.find { |row| row.as_h["domain_run_id"]?.try(&.as_s?) == run["run_id"].as_s }.not_nil!.as_h
        delta["evidence"].as_h["created"].as_i.should eq(2)
        delta["status"].as_s.should eq("complete")

        rt.errors.should be_empty
      end
    end

    it "is idempotent for an identical bounded window" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        backfill = ->(surface_id : String) {
          Chronicle::Packs::Gmail.request_gmail_backfill_fn(
            graph,
            source_surface_id: surface_id,
            account_ref: "yohei@example.com",
            user_id: "agent:owner",
            connected_account_id: "ca_1",
            query: "newer_than:30d",
            page_size: 1,
            max_messages: 2,
            max_pages: 2,
          )
        }
        backfill.call(object_data(surface)["surface_id"].as_s)
        rt.run_until_idle
        again = backfill.call(object_data(surface)["surface_id"].as_s)
        rt.run_until_idle

        again["created"].as_bool.should be_false
        graph.objects(type: "activity_evidence").size.should eq(2)
        graph.objects(type: "gmail_sync_run").size.should eq(1)
      end
    end

    it "restarts an interrupted backfill with overlap and dedups" do
      with_gmail_runtime do |_store, graph, rt, fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        fake.fail_next_fetch = true
        first = Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          page_size: 1,
          max_messages: 2,
          max_pages: 2,
        )
        rt.run_until_idle
        object_data(graph.get_object(first["run_id"].as_s).not_nil!)["status"].as_s.should eq("failed")

        resumed = Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          page_size: 1,
          max_messages: 2,
          max_pages: 2,
        )
        rt.run_until_idle
        resumed["resumed"].as_bool.should be_true
        object_data(graph.get_object(first["run_id"].as_s).not_nil!)["status"].as_s.should eq("completed")
        graph.objects(type: "activity_evidence").size.should eq(2)
      end
    end

    it "marks a bound hit as partial and refuses an identical re-request" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        first = Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          page_size: 1,
          max_messages: 1,
          max_pages: 1,
        )
        rt.run_until_idle
        object_data(graph.get_object(first["run_id"].as_s).not_nil!)["status"].as_s.should eq("partial")
        same = Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          page_size: 1,
          max_messages: 1,
          max_pages: 1,
        )
        same["created"].as_bool.should be_false
        same["run_id"].as_s.should eq(first["run_id"].as_s)
        graph.objects(type: "gmail_sync_run").size.should eq(1)
      end
    end
  end

  describe "history polling" do
    it "imports additions, tombstones deletions, and advances the watermark" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        surface_id = object_data(surface)["surface_id"].as_s
        Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: surface_id,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          query: "newer_than:30d",
          page_size: 1,
          max_messages: 2,
          max_pages: 2,
        )
        rt.run_until_idle
        m1 = graph.objects(type: "activity_evidence").find { |obj| object_data(obj)["provider_item_id"]?.try(&.as_s?) == "m1" }.not_nil!

        poll = Chronicle::Packs::Gmail.request_gmail_poll_fn(
          graph,
          source_surface_id: surface_id,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          start_history_id: "900",
        )
        rt.run_until_idle

        poll_run = graph.get_object(poll["run_id"].as_s).not_nil!
        object_data(poll_run)["status"].as_s.should eq("completed")
        graph.objects(type: "activity_evidence").size.should eq(3)
        object_data(graph.get_object(m1.id).not_nil!)["status"].as_s.should eq("revoked")
        tombstone = graph.objects(type: "evidence_invalidation_request").first.not_nil!
        td = object_data(tombstone)
        td["status"].as_s.should eq("fulfilled")
        td["invalidated_evidence_ids"].as_a.map(&.as_s).should eq([m1.id])
        usage_evidence = graph.objects(type: "usage_evidence").find { |obj| object_data(obj)["evidence_id"]?.try(&.as_s?) == m1.id }.not_nil!
        object_data(usage_evidence)["invalidated"].as_bool.should be_true
        cursor = graph.objects(type: "backfill_cursor").first.not_nil!
        object_data(cursor)["watermark_ref"].as_s.should eq("history:901")
        rt.errors.should be_empty
      end
    end

    it "settles a missing history message as a concurrent deletion" do
      with_gmail_runtime do |_store, graph, rt, fake|
        fake.missing_history_message = true
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        poll = Chronicle::Packs::Gmail.request_gmail_poll_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          start_history_id: "900",
        )
        rt.run_until_idle

        run = graph.get_object(poll["run_id"].as_s).not_nil!
        rd = object_data(run)
        rd["status"].as_s.should eq("completed")
        rd["completed_message_ids"].as_a.map(&.as_s).should eq(["m3"])
        rd["missing_message_ids"].as_a.map(&.as_s).should eq(["m-gone"])
        rd["messages_imported"].as_i.should eq(1)
        rd["deleted_message_ids"].as_a.map(&.as_s).to_set.should eq(Set{"m1", "m-gone"})
        rd["tombstones_recorded"].as_i.should eq(2)
        cursor = graph.objects(type: "backfill_cursor").first.not_nil!
        object_data(cursor)["watermark_ref"].as_s.should eq("history:901")
        tombstones = graph.objects(type: "evidence_invalidation_request").map { |obj| object_data(obj)["provider_item_id"].as_s }
        tombstones.to_set.should eq(Set{"m1", "m-gone"})
        observation = graph.objects(type: "connector_run_observation").find { |obj| object_data(obj)["domain_run_id"]?.try(&.as_s?) == run.id }.not_nil!
        od = object_data(observation)
        od["state"].as_s.should eq("succeeded")
        od["cursor"].as_h["advanced"].as_bool.should be_true
      end
    end

    it "retries a rate-limited poll and requires reanchor for an invalid cursor" do
      with_gmail_runtime do |_store, graph, rt, fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        surface_id = object_data(surface)["surface_id"].as_s

        fake.rate_limit_next_history = true
        first = Chronicle::Packs::Gmail.request_gmail_poll_fn(
          graph,
          source_surface_id: surface_id,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          start_history_id: "900",
        )
        rt.run_until_idle
        object_data(graph.get_object(first["run_id"].as_s).not_nil!)["error_code"].as_s.should eq("rate_limited")
        retried = Chronicle::Packs::Gmail.request_gmail_poll_fn(
          graph,
          source_surface_id: surface_id,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          start_history_id: "900",
        )
        rt.run_until_idle
        retried["resumed"].as_bool.should be_true
        object_data(graph.get_object(first["run_id"].as_s).not_nil!)["status"].as_s.should eq("completed")

        fake.invalid_cursor_next_history = true
        invalid = Chronicle::Packs::Gmail.request_gmail_poll_fn(
          graph,
          source_surface_id: surface_id,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          start_history_id: "899",
        )
        rt.run_until_idle
        run = graph.get_object(invalid["run_id"].as_s).not_nil!
        rd = object_data(run)
        rd["error_code"].as_s.should eq("cursor_invalid")
        rd["metadata"].as_h["reanchor_required"].as_bool.should be_true
        observation = graph.objects(type: "connector_run_observation").find { |obj| object_data(obj)["domain_run_id"]?.try(&.as_s?) == run.id }.not_nil!
        od = object_data(observation)
        od["cursor"].as_h["has_position"].as_bool.should be_true
        od["cursor"].as_h["advanced"].as_bool.should be_false
      end
    end
  end

  describe "draft lifecycle" do
    it "keeps a local draft R1 and never auto-runs the R2 sync or R3 send" do
      with_gmail_runtime do |_store, graph, rt, _fake|
        draft, created = Chronicle::Packs::Gmail.create_gmail_draft_candidate_fn(
          graph,
          account_ref: "yohei@example.com",
          connected_account_id: "ca_1",
          to: ["person@example.com"],
          subject: "Hello",
          body: "Draft body",
        )
        rt.run_until_idle
        created.should be_true
        object_data(draft)["status"].as_s.should eq("local_draft")

        synced = Chronicle::Packs::Gmail.request_gmail_draft_sync_fn(graph, draft_id: draft.id, user_id: "agent:owner")
        rt.run_until_idle
        sync_call = graph.get_object(synced["call_id"].as_s).not_nil!
        sd = object_data(sync_call)
        sd["action_class"].as_s.should eq("R2")
        sd["status"].as_s.should eq("policy_checking")
        graph.objects(type: "capability_result").any? { |obj| object_data(obj)["call_id"]?.try(&.as_s?) == sync_call.id }.should be_false

        approved = Chronicle::Packs::ToolGateway.approve_capability_fn(graph, sync_call.id, approver_ref: "owner:client")
        approved["ok"].as_bool.should be_true
        rt.run_until_idle
        draft = graph.get_object(draft.id).not_nil!
        dd = object_data(draft)
        dd["status"].as_s.should eq("synced")
        dd["provider_draft_id"].as_s.should eq("provider-result")

        proposed = Chronicle::Packs::Gmail.request_gmail_draft_send_fn(graph, draft_id: draft.id, user_id: "agent:owner")
        rt.run_until_idle
        send = graph.get_object(proposed["call_id"].as_s).not_nil!
        object_data(send)["action_class"].as_s.should eq("R3")
        object_data(send)["status"].as_s.should eq("policy_checking")
        graph.objects(type: "capability_result").any? { |obj| object_data(obj)["call_id"]?.try(&.as_s?) == send.id }.should be_false

        again = Chronicle::Packs::Gmail.request_gmail_draft_send_fn(graph, draft_id: draft.id, user_id: "agent:owner")
        again["created"].as_bool.should be_false
        again["call_id"].as_s.should eq(send.id)
      end
    end
  end

  describe "failure posture" do
    it "records drift on an unexpected shape and re-explores with force" do
      with_gmail_runtime do |_store, graph, rt, fake|
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1")
        rt.run_until_idle
        surface = surface_for(graph)
        fake.bad_shape_next_fetch = true
        started = Chronicle::Packs::Gmail.request_gmail_backfill_fn(
          graph,
          source_surface_id: object_data(surface)["surface_id"].as_s,
          account_ref: "yohei@example.com",
          user_id: "agent:owner",
          connected_account_id: "ca_1",
          max_messages: 1,
          max_pages: 1,
        )
        rt.run_until_idle

        run = graph.get_object(started["run_id"].as_s).not_nil!
        rd = object_data(run)
        rd["status"].as_s.should eq("failed")
        rd["error_code"].as_s.should eq("unexpected_shape")
        graph.objects(type: "ingestion_failure").any? { |obj| object_data(obj)["error_code"]?.try(&.as_s?) == "gmail.unexpected_shape" }.should be_true

        profiles = graph.objects(type: "integration_profile").sort_by! { |obj| object_data(obj)["profile_version"].as_i }
        latest = profiles.last.not_nil!
        ld = object_data(latest)
        ld["status"].as_s.should eq("stale")
        ld["health"].as_h["drift_reason"].as_s.should eq("unexpected_shape")
        ld["claims"].as_a.all? { |claim| claim.as_h["freshness"].as_s == "stale" }.should be_true

        refreshed = Chronicle::Packs::Gmail.request_gmail_exploration_fn(graph, user_id: "agent:owner", connected_account_id: "ca_1", force: true)
        rt.run_until_idle
        refreshed["created"].as_bool.should be_true
        current = graph.objects(type: "integration_profile").sort_by! { |obj| object_data(obj)["profile_version"].as_i }.last.not_nil!
        cd = object_data(current)
        cd["status"].as_s.should eq("active")
        cd["profile_version"].as_i.should eq(3)
      end
    end
  end

  describe "non-composio route adapter" do
    it "accepts a native route without an aggregator or Composio dependency" do
      with_gmail_runtime do |_store, graph, rt, fake|
        Chronicle::Packs::Gmail.register_gmail_capabilities(
          artifact_store_dir: artifact_dir,
          route: "native",
          execute_route: ->(provider_operation : String, arguments : Hash(String, JSON::Any), user_id : String, connected_account_id : String, schema_version : String) : JSON::Any {
            JSON::Any.new(fake.execute(tool_slug: provider_operation, arguments: arguments, user_id: user_id, connected_account_id: connected_account_id, version: schema_version))
          },
        )
        Chronicle::Packs::Gmail.request_gmail_exploration_fn(
          graph,
          user_id: "agent:owner",
          connected_account_id: "native-account-1",
          route: "native",
        )
        rt.run_until_idle

        profile = graph.objects(type: "integration_profile").find { |obj| object_data(obj)["status"].as_s == "active" }.not_nil!
        pd = object_data(profile)
        pd["routes"].as_a.first.as_h["path"].as_s.should eq("native")
        surface = surface_for(graph)
        object_data(surface)["path"].as_s.should eq("native")
        graph.objects(type: "aggregator_profile").should be_empty
        pd["capability_inventory"].as_a.all? { |row| row.as_h["route"].as_s == "native" }.should be_true
      end
    end
  end
end

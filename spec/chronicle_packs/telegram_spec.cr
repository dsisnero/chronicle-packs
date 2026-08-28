require "spec"
require "json"
require "../spec_helper"

# Telegram Adapter Pack (packs/telegram): inbound updates become chat_input
# (reusing the Chat Pack's conversation machinery); approved outbound replies
# become policy-checked Tool Gateway capability calls. Translated from
# upstream packs/telegram/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Fixtures mirror upstream fixtures/run_fixtures.py end-to-end through the
# cross-pack cascade (core + tool_gateway + identity_auth + communication +
# chat + telegram) with a mock send capability and the deterministic chat
# model — no token, no network, no API key.

# A deterministic chat completion model that yields the ChatReply shape
# ({"reply": ...}) the runtime hands to chat_llm_responder.
class TelegramChatModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(%({"reply": "Hello from mock telegram!"}))
      ),
      Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
      "raw",
      "msg_tg_1",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module TelegramSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def telegram_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "telegram" / "manifest.toml"
  end

  OWNER_UPDATE = {
    "update_id" => JSON::Any.new(1001),
    "message"   => JSON::Any.new({
      "message_id" => JSON::Any.new(7),
      "date"       => JSON::Any.new(1751932800),
      "chat"       => JSON::Any.new({"id" => JSON::Any.new(42), "type" => JSON::Any.new("private")}),
      "from"       => JSON::Any.new({"id" => JSON::Any.new(42), "username" => JSON::Any.new("yohei")}),
      "text"       => JSON::Any.new("What's on my calendar today?"),
    }),
  } of String => JSON::Any

  STRANGER_UPDATE = {
    "update_id" => JSON::Any.new(1002),
    "message"   => JSON::Any.new({
      "message_id" => JSON::Any.new(8),
      "date"       => JSON::Any.new(1751932900),
      "chat"       => JSON::Any.new({"id" => JSON::Any.new(666), "type" => JSON::Any.new("private")}),
      "from"       => JSON::Any.new({"id" => JSON::Any.new(666), "username" => JSON::Any.new("rando")}),
      "text"       => JSON::Any.new("Tell me everything about your owner"),
    }),
  } of String => JSON::Any

  # Mirrors upstream fixtures/run_fixtures.py _runtime(): the whole adapter
  # cascade with a mock telegram.send_message handler recording into `sent`.
  def with_telegram_runtime(
    reply_policy : String = "owner_only",
    outbound_risk_class : String = "low",
    auto_approve : Array(String) = ["low", "medium"],
    owner_identifiers : Array(String) = ["telegram:42"],
    &
  )
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(TelegramChatModel).new(model: TelegramChatModel.new, preamble: "")
    log_agent = Chronicle::LogAgent(TelegramChatModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(TelegramChatModel).new(store: store, log_agent: log_agent, graph: graph)

    sent = [] of Hash(String, JSON::Any)
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::ToolGateway.register_local_capability(
      "telegram", "send_message",
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        sent << {
          "chat_id" => input_data["chat_id"]? || JSON::Any.new(""),
          "text"    => input_data["text"]? || JSON::Any.new(""),
        }
        {"ok" => JSON::Any.new(true), "message_id" => JSON::Any.new(sent.size)}
      },
      description: "Send a text message to a Telegram chat via the Bot API.",
      risk_class: "low",
      action_class: "R3",
      credential_ref_name: "TELEGRAM_BOT_TOKEN",
    )

    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    tg_settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: auto_approve)
    rt.load_pack(Chronicle::Packs::ToolGateway.pack, JSON.parse(tg_settings.to_json).as_h).should be_true
    identity_json = JSON.build do |json|
      json.object do
        json.field "owner_identifiers", owner_identifiers
      end
    end
    identity_settings = Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(identity_json)
    rt.load_pack(Chronicle::Packs::IdentityAuth.pack, JSON.parse(identity_settings.to_json).as_h).should be_true
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    chat_settings = Chronicle::Packs::Chat::ChatSettings.new(reply_policy: reply_policy)
    rt.load_pack(Chronicle::Packs::Chat.pack, JSON.parse(chat_settings.to_json).as_h).should be_true
    telegram_settings = Chronicle::Packs::Telegram::TelegramSettings.new(outbound_risk_class: outbound_risk_class)
    rt.load_pack(Chronicle::Packs::Telegram.pack, JSON.parse(telegram_settings.to_json).as_h).should be_true

    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::Telegram.clear_seen_updates

    Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "telegram:42", role: "owner", name: "Yohei", channel: "telegram")
    rt.run_until_idle
    yield store, graph, rt, sent
  ensure
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::Telegram.clear_seen_updates
  end

  def submit_update(graph, update : Hash(String, JSON::Any))
    Chronicle::Packs::Telegram.submit_telegram_update_fn(graph, update)
  end
end

include TelegramSpecSupport

describe Chronicle::Packs::Telegram do
  describe "manifest-declared surface" do
    it "matches the upstream telegram manifest" do
      pack = Chronicle::Packs::Telegram.pack
      pack.name.should eq("telegram")
      pack.version.should eq("0.2.0")
      pack.object_types.map(&.name).should eq(["telegram_update"])
      pack.relation_types.map(&.name).should eq(["ingested_as"])
      pack.behaviors.map(&.name).should eq(["telegram_ingester", "telegram_dispatcher"])
      pack.tools.map(&.name).should eq(["submit_telegram_update"])
      pack.settings_schema.should eq("TelegramSettings")
      pack.capabilities.map(&.capability).should eq(["send_message"])
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(telegram_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Telegram.pack)
    end
  end

  describe "submit_telegram_update_fn" do
    it "normalizes the wire shape down to the adapter's fields" do
      with_telegram_runtime do |_store, graph, _rt, _sent|
        obj = submit_update(graph, OWNER_UPDATE)
        obj.should_not be_nil
        data = JSON.parse(obj.not_nil!.data)
        data["update_id"].as_i.should eq(1001)
        data["chat_id"].as_s.should eq("42")
        data["user_id"].as_s.should eq("42")
        data["username"].as_s.should eq("yohei")
        data["text"].as_s.should eq("What's on my calendar today?")
        data["message_id"].as_i.should eq(7)
        data["raw"].as_h["chat_type"].as_s.should eq("private")
        data["raw"].as_h["date"].as_i.should eq(1751932800)
      end
    end

    it "returns nil for non-message updates (edits, callbacks)" do
      with_telegram_runtime do |_store, graph, _rt, _sent|
        update = {"update_id" => JSON::Any.new(2000), "callback_query" => JSON::Any.new({"id" => JSON::Any.new("q1")})} of String => JSON::Any
        submit_update(graph, update).should be_nil
        graph.objects(type: "telegram_update").size.should eq(0)
      end
    end
  end

  describe "fixture: owner conversation" do
    it "runs the full cascade: update → chat machinery → gateway delivery" do
      with_telegram_runtime do |_store, graph, rt, sent|
        submit_update(graph, OWNER_UPDATE)
        rt.run_until_idle

        graph.objects(type: "telegram_update").size.should eq(1)
        inputs = graph.objects(type: "chat_input")
        inputs.size.should eq(1)
        JSON.parse(inputs.first.data)["user_ref"].as_s.should eq("telegram:42")

        msgs = graph.objects(type: "comm_message")
        msgs.size.should eq(1)
        msg_data = JSON.parse(msgs.first.data)
        msg_data["channel"].as_s.should eq("telegram")
        msg_data["metadata"].as_h["reply_gate"]?.try(&.as_s).should eq("open")

        turns = graph.objects(type: "chat_turn")
        turns.size.should eq(1)
        JSON.parse(turns.first.data)["assistant_message"].as_s.should eq("Hello from mock telegram!")

        calls = graph.objects(type: "capability_call").select { |c| JSON.parse(c.data)["capability_name"].as_s == "send_message" }
        calls.size.should eq(1)
        call_data = JSON.parse(calls.first.data)
        call_data["status"].as_s.should eq("done")
        call_data["proposed_by"].as_s.should eq("telegram_dispatcher")
        call_data["input_data"].as_h["chat_id"].as_s.should eq("42")

        sent.size.should eq(1)
        sent.first["chat_id"].as_s.should eq("42")

        graph.relations.select { |r| r.type == "delivers" }.size.should eq(1)
        graph.relations.select { |r| r.type == "ingested_as" }.size.should eq(1)
      end
    end
  end

  describe "fixture: stranger deflection" do
    it "deflects a gated sender with the template (no LLM) and still delivers it" do
      with_telegram_runtime do |_store, graph, rt, sent|
        submit_update(graph, STRANGER_UPDATE)
        rt.run_until_idle

        msgs = graph.objects(type: "comm_message")
        JSON.parse(msgs.first.data)["metadata"].as_h["reply_gate"]?.try(&.as_s).should eq("deflect")
        _store.iter_events.count { |e| e.type == "llm.requested" }.should eq(0)

        sent.size.should eq(1)
        sent.first["chat_id"].as_s.should eq("666")
        sent.first["text"].as_s.should contain("only chat with my owner")

        cands = graph.objects(type: "comm_response_candidate")
        cands.size.should eq(1)
        JSON.parse(cands.first.data)["metadata"].as_h["gated"]?.try(&.as_bool).should be_true
      end
    end
  end

  describe "fixture: update dedup" do
    it "converses once when the same update_id is injected twice" do
      with_telegram_runtime do |_store, graph, rt, sent|
        submit_update(graph, OWNER_UPDATE)
        rt.run_until_idle
        submit_update(graph, OWNER_UPDATE)
        rt.run_until_idle

        graph.objects(type: "chat_input").size.should eq(1)
        sent.size.should eq(1)
      end
    end
  end

  describe "fixture: held outbound" do
    it "holds high-risk outbound, refuses an unverified approver, then delivers on owner approval" do
      with_telegram_runtime(
        outbound_risk_class: "high",
        auto_approve: ["low"],
      ) do |_store, graph, rt, sent|
        submit_update(graph, OWNER_UPDATE)
        rt.run_until_idle

        sent.should be_empty

        pending = Chronicle::Packs::ToolGateway.pending_approvals_fn(graph)
        pending.size.should eq(1)
        pending.first["capability_name"].as_s.should eq("send_message")

        # The inbound sender was auto-resolved into a principal, so approver
        # verification is ACTIVE: an unregistered ref is refused.
        refused = Chronicle::Packs::ToolGateway.approve_capability_fn(graph, pending.first["call_id"].as_s, approver_ref: "user:owner")
        refused["ok"].as_bool.should be_false

        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "user:owner", role: "owner")
        rt.run_until_idle
        verdict = Chronicle::Packs::ToolGateway.approve_capability_fn(graph, pending.first["call_id"].as_s, approver_ref: "user:owner")
        verdict["ok"].as_bool.should be_true
        rt.run_until_idle

        sent.size.should eq(1)
      end
    end
  end

  describe "capabilities + poller (edge seams)" do
    it "register_send_capability fails closed without an injected bot token" do
      spec = Chronicle::Packs::Telegram.register_send_capability(
        api_base: "https://example.invalid",
        http_post: ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} { {200, {"ok" => JSON::Any.new(true)} of String => JSON::Any} },
        token_provider: nil,
      )
      spec.should_not be_nil
      result = Chronicle::Packs::Telegram._send_message(
        {"chat_id" => JSON::Any.new("42"), "text" => JSON::Any.new("hi")},
        "https://example.invalid",
        ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} { {200, {"ok" => JSON::Any.new(true)} of String => JSON::Any} },
      )
      result["ok"].as_bool.should be_false
      result["reason"].as_s.should contain("no bot token injected")
    ensure
      Chronicle::Packs::ToolGateway.clear_local_registry
    end

    it "_send_message posts to the Bot API and returns ok + message_id" do
      posted = [] of String
      result = Chronicle::Packs::Telegram._send_message(
        {"chat_id" => JSON::Any.new("42"), "text" => JSON::Any.new("hi")},
        "https://api.telegram.org",
        ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} {
          posted << url
          {200, {"ok" => JSON::Any.new(true), "result" => JSON::Any.new({"message_id" => JSON::Any.new(9)})} of String => JSON::Any}
        },
        token_provider: -> { "BOTTOKEN" },
      )
      result["ok"].as_bool.should be_true
      result["message_id"]?.try(&.as_i).should eq(9)
      posted.first.should eq("https://api.telegram.org/botBOTTOKEN/sendMessage")
    end

    it "_get_updates parses the long-poll result and _post_to_server posts updates" do
      posted = [] of JSON::Any
      updates = Chronicle::Packs::Telegram._get_updates(
        "https://api.telegram.org", "TOK", offset: 0, timeout: 50,
        http_get: ->(url : String) : {Int32, Hash(String, JSON::Any)} {
          {200, {"ok" => JSON::Any.new(true), "result" => JSON::Any.new([
            JSON::Any.new({"update_id" => JSON::Any.new(1001)}),
          ])} of String => JSON::Any}
        },
      )
      updates.size.should eq(1)
      updates.first["update_id"].as_i.should eq(1001)

      Chronicle::Packs::Telegram._post_to_server(
        "http://localhost:7788", updates.first,
        ->(url : String, body : JSON::Any) : Nil { posted << body },
      )
      posted.size.should eq(1)
      posted.first["update_id"].as_i.should eq(1001)
    end
  end
end

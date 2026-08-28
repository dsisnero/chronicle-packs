require "spec"
require "json"
require "../spec_helper"

# WhatsApp Adapter Pack (packs/whatsapp): inbound Cloud API webhooks become
# chat_input (reusing the Chat Pack's conversation machinery); approved
# outbound replies become policy-checked Tool Gateway capability calls.
# Structurally the mirror of the Telegram Adapter Pack. Translated from
# upstream packs/whatsapp/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Fixtures mirror upstream fixtures/run_fixtures.py end-to-end through the
# cross-pack cascade with a mock send capability and the deterministic chat
# model — no token, no network, no API key.

# A deterministic chat completion model that yields the ChatReply shape.
class WhatsAppChatModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(%({"reply": "Hello from mock whatsapp!"}))
      ),
      Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
      "raw",
      "msg_wa_1",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module WhatsAppSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def whatsapp_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "whatsapp" / "manifest.toml"
  end

  OWNER_PHONE    = "15550001111"
  STRANGER_PHONE = "15559998888"

  # A Cloud API webhook envelope, as Meta actually delivers it.
  def envelope(from_number : String, name : String, text : String, wamid : String)
    {
      "object" => JSON::Any.new("whatsapp_business_account"),
      "entry"  => JSON::Any.new([
        JSON::Any.new({
          "id"      => JSON::Any.new("1234567890"),
          "changes" => JSON::Any.new([
            JSON::Any.new({
              "field" => JSON::Any.new("messages"),
              "value" => JSON::Any.new({
                "messaging_product" => JSON::Any.new("whatsapp"),
                "metadata"          => JSON::Any.new({"phone_number_id" => JSON::Any.new("555000111222")}),
                "contacts"          => JSON::Any.new([
                  JSON::Any.new({"wa_id" => JSON::Any.new(from_number), "profile" => JSON::Any.new({"name" => JSON::Any.new(name)})}),
                ]),
                "messages" => JSON::Any.new([
                  JSON::Any.new({
                    "id"        => JSON::Any.new(wamid),
                    "from"      => JSON::Any.new(from_number),
                    "timestamp" => JSON::Any.new("1751932800"),
                    "type"      => JSON::Any.new("text"),
                    "text"      => JSON::Any.new({"body" => JSON::Any.new(text)}),
                  }),
                ]),
              }),
            }),
          ]),
        }),
      ]),
    } of String => JSON::Any
  end

  # Mirrors upstream fixtures/run_fixtures.py _runtime().
  def with_whatsapp_runtime(
    reply_policy : String = "owner_only",
    outbound_risk_class : String = "low",
    auto_approve : Array(String) = ["low", "medium"],
    &
  )
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(WhatsAppChatModel).new(model: WhatsAppChatModel.new, preamble: "")
    log_agent = Chronicle::LogAgent(WhatsAppChatModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(WhatsAppChatModel).new(store: store, log_agent: log_agent, graph: graph)

    sent = [] of Hash(String, JSON::Any)
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::ToolGateway.register_local_capability(
      "whatsapp", "send_message",
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        sent << {
          "to"   => input_data["to"]? || JSON::Any.new(""),
          "text" => input_data["text"]? || JSON::Any.new(""),
        }
        {"ok" => JSON::Any.new(true), "message_id" => JSON::Any.new("wamid.out#{sent.size}")}
      },
      description: "Send a text message via the WhatsApp Cloud API.",
      risk_class: "low",
      action_class: "R3",
      credential_ref_name: "WHATSAPP_ACCESS_TOKEN",
    )

    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    tg_settings = Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(auto_approve_risk_classes: auto_approve)
    rt.load_pack(Chronicle::Packs::ToolGateway.pack, JSON.parse(tg_settings.to_json).as_h).should be_true
    identity_json = JSON.build do |json|
      json.object do
        json.field "owner_identifiers", ["whatsapp:#{OWNER_PHONE}"]
      end
    end
    identity_settings = Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(identity_json)
    rt.load_pack(Chronicle::Packs::IdentityAuth.pack, JSON.parse(identity_settings.to_json).as_h).should be_true
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    chat_settings = Chronicle::Packs::Chat::ChatSettings.new(reply_policy: reply_policy)
    rt.load_pack(Chronicle::Packs::Chat.pack, JSON.parse(chat_settings.to_json).as_h).should be_true
    whatsapp_settings = Chronicle::Packs::WhatsApp::WhatsAppSettings.new(phone_number_id: "555000111222", outbound_risk_class: outbound_risk_class)
    rt.load_pack(Chronicle::Packs::WhatsApp.pack, JSON.parse(whatsapp_settings.to_json).as_h).should be_true

    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::WhatsApp.clear_seen_messages

    Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "whatsapp:#{OWNER_PHONE}", role: "owner", name: "Yohei", channel: "whatsapp")
    rt.run_until_idle
    yield store, graph, rt, sent
  ensure
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::WhatsApp.clear_seen_messages
  end

  def submit_webhook(graph, payload : Hash(String, JSON::Any))
    Chronicle::Packs::WhatsApp.submit_whatsapp_webhook_fn(graph, payload)
  end
end

include WhatsAppSpecSupport

describe Chronicle::Packs::WhatsApp do
  describe "manifest-declared surface" do
    it "matches the upstream whatsapp manifest" do
      pack = Chronicle::Packs::WhatsApp.pack
      pack.name.should eq("whatsapp")
      pack.version.should eq("0.2.0")
      pack.object_types.map(&.name).should eq(["whatsapp_message"])
      pack.relation_types.map(&.name).should eq(["wa_ingested_as"])
      pack.behaviors.map(&.name).should eq(["whatsapp_ingester", "whatsapp_dispatcher"])
      pack.tools.map(&.name).should eq(["submit_whatsapp_webhook"])
      pack.settings_schema.should eq("WhatsAppSettings")
      pack.capabilities.map(&.capability).should eq(["send_message"])
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(whatsapp_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::WhatsApp.pack)
    end
  end

  describe "submit_whatsapp_webhook_fn" do
    it "unwraps a Cloud API envelope into whatsapp_message objects" do
      with_whatsapp_runtime do |_store, graph, _rt, _sent|
        created = submit_webhook(graph, envelope(OWNER_PHONE, "Yohei", "What's on my calendar today?", "wamid.abc1"))
        created.size.should eq(1)
        data = JSON.parse(created.first.data)
        data["message_id"].as_s.should eq("wamid.abc1")
        data["from_number"].as_s.should eq(OWNER_PHONE)
        data["profile_name"].as_s.should eq("Yohei")
        data["text"].as_s.should eq("What's on my calendar today?")
        data["timestamp"].as_s.should eq("1751932800")
        data["raw"].as_h["type"].as_s.should eq("text")
      end
    end

    it "skips non-text messages (media, reactions) cleanly" do
      with_whatsapp_runtime do |_store, graph, _rt, sent|
        env = envelope(OWNER_PHONE, "Yohei", "ignored", "wamid.img1")
        messages = env["entry"].as_a.first["changes"].as_a.first["value"].as_h["messages"].as_a
        messages.first.as_h["type"] = JSON::Any.new("image")

        created = submit_webhook(graph, env)
        created.should be_empty
        graph.objects(type: "whatsapp_message").size.should eq(0)
        sent.should be_empty
      end
    end
  end

  describe "fixture: owner conversation" do
    it "runs the full cascade: webhook → chat machinery → gateway delivery" do
      with_whatsapp_runtime do |_store, graph, rt, sent|
        submit_webhook(graph, envelope(OWNER_PHONE, "Yohei", "What's on my calendar today?", "wamid.abc1"))
        rt.run_until_idle

        inputs = graph.objects(type: "chat_input")
        inputs.size.should eq(1)
        JSON.parse(inputs.first.data)["user_ref"].as_s.should eq("whatsapp:#{OWNER_PHONE}")

        msgs = graph.objects(type: "comm_message")
        msgs.size.should eq(1)
        msg_data = JSON.parse(msgs.first.data)
        msg_data["channel"].as_s.should eq("whatsapp")
        msg_data["metadata"].as_h["reply_gate"]?.try(&.as_s).should eq("open")

        turns = graph.objects(type: "chat_turn")
        turns.size.should eq(1)
        JSON.parse(turns.first.data)["assistant_message"].as_s.should eq("Hello from mock whatsapp!")

        calls = graph.objects(type: "capability_call").select { |c| JSON.parse(c.data)["capability_name"].as_s == "send_message" }
        calls.size.should eq(1)
        call_data = JSON.parse(calls.first.data)
        call_data["status"].as_s.should eq("done")
        call_data["proposed_by"].as_s.should eq("whatsapp_dispatcher")
        call_data["input_data"].as_h["to"].as_s.should eq(OWNER_PHONE)

        sent.size.should eq(1)
        sent.first["to"].as_s.should eq(OWNER_PHONE)

        graph.relations.select { |r| r.type == "delivers" }.size.should eq(1)
        graph.relations.select { |r| r.type == "wa_ingested_as" }.size.should eq(1)
      end
    end
  end

  describe "fixture: stranger deflection" do
    it "deflects a gated sender with the template (no LLM) and still delivers it" do
      with_whatsapp_runtime do |_store, graph, rt, sent|
        submit_webhook(graph, envelope(STRANGER_PHONE, "Rando", "Who do you work for?", "wamid.xyz9"))
        rt.run_until_idle

        msgs = graph.objects(type: "comm_message")
        JSON.parse(msgs.first.data)["metadata"].as_h["reply_gate"]?.try(&.as_s).should eq("deflect")
        _store.iter_events.count { |e| e.type == "llm.requested" }.should eq(0)

        sent.size.should eq(1)
        sent.first["to"].as_s.should eq(STRANGER_PHONE)
        sent.first["text"].as_s.should contain("only chat with my owner")

        cands = graph.objects(type: "comm_response_candidate")
        cands.size.should eq(1)
        JSON.parse(cands.first.data)["metadata"].as_h["gated"]?.try(&.as_bool).should be_true
      end
    end
  end

  describe "fixture: webhook dedup" do
    it "converses once when the same wamid is delivered twice (Meta retries)" do
      with_whatsapp_runtime do |_store, graph, rt, sent|
        env = envelope(OWNER_PHONE, "Yohei", "hello!", "wamid.dup1")
        submit_webhook(graph, env)
        rt.run_until_idle
        submit_webhook(graph, env)
        rt.run_until_idle

        graph.objects(type: "chat_input").size.should eq(1)
        sent.size.should eq(1)
      end
    end
  end

  describe "capabilities (edge seams)" do
    it "register_send_capability fails closed without a token or phone_number_id" do
      result = Chronicle::Packs::WhatsApp._send_message(
        {"to" => JSON::Any.new("15550001111"), "text" => JSON::Any.new("hi")},
        "https://graph.facebook.com/v20.0",
        "555000111222",
        ->(url : String, data : JSON::Any) : {Int32, Hash(String, JSON::Any)} { {200, {"messages" => JSON::Any.new([JSON::Any.new({"id" => JSON::Any.new("wamid.out1")})])} of String => JSON::Any} },
        token_provider: nil,
      )
      result["ok"].as_bool.should be_false
      result["reason"].as_s.should contain("no access token injected")
    ensure
      Chronicle::Packs::ToolGateway.clear_local_registry
    end

    it "_send_message posts to the Cloud API messages endpoint and returns ok + message_id" do
      posted = [] of String
      result = Chronicle::Packs::WhatsApp._send_message(
        {"to" => JSON::Any.new("15550001111"), "text" => JSON::Any.new("hi")},
        "https://graph.facebook.com/v20.0",
        "555000111222",
        ->(url : String, data : JSON::Any) : {Int32, Hash(String, JSON::Any)} {
          posted << url
          {200, {"messages" => JSON::Any.new([JSON::Any.new({"id" => JSON::Any.new("wamid.out1")})])} of String => JSON::Any}
        },
        token_provider: -> { "ACCESSTOKEN" },
      )
      result["ok"].as_bool.should be_true
      result["message_id"]?.try(&.as_s).should eq("wamid.out1")
      posted.first.should eq("https://graph.facebook.com/v20.0/555000111222/messages")
    end

    it "_send_message fails closed when phone_number_id is not configured" do
      result = Chronicle::Packs::WhatsApp._send_message(
        {"to" => JSON::Any.new("15550001111"), "text" => JSON::Any.new("hi")},
        "https://graph.facebook.com/v20.0",
        "",
        ->(url : String, data : JSON::Any) : {Int32, Hash(String, JSON::Any)} { {200, {"messages" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any} },
        token_provider: -> { "ACCESSTOKEN" },
      )
      result["ok"].as_bool.should be_false
      result["reason"].as_s.should contain("phone_number_id not configured")
    end
  end
end

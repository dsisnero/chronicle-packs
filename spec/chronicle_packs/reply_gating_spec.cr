require "spec"
require "../spec_helper"

# End-to-end reply gating (identity on the respond path, upstream
# tests/test_reply_gating.py). Under a restrictive reply policy, the owner
# gets a full LLM reply with an owner-scoped profile, while a stranger gets
# the bounded deflection template — with NO llm.requested event, no memory
# proposal, and the gate verdict auditable on the graph objects.

module ReplyGatingSpecSupport
  extend self

  OWNER = "yohei@example.com"

  # A counting mock completion model: returns a fixed reply, counts
  # invocations (the gate must keep it at 0 for deflected senders).
  class CountingModel
    include Crig::Completion::CompletionModel

    getter calls : Int32 = 0

    def completion(request : Crig::Completion::Request::CompletionRequest)
      @calls += 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text(%({"reply": "Here is your full answer."}))
        ),
        Crig::Completion::Usage.new(input_tokens: 0, output_tokens: 0),
        "raw",
        "msg_reply",
      )
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "not implemented in test"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end

  def build(policy : String) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(CountingModel), CountingModel}
    model = CountingModel.new
    agent = Crig::Agent(CountingModel).new(model: model, preamble: "")
    # build_assistant constructs its own agent; to use the counting model we
    # build the runtime by hand over the assistant packs.
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    la = Chronicle::LogAgent(CountingModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(CountingModel).new(store: store, log_agent: la, graph: graph)
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Bundles.load_assistant_packs(
      rt,
      chat_settings: Chronicle::Packs::Chat::ChatSettings.new(reply_policy: policy),
      identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["#{OWNER}"]})),
    )
    Chronicle::Packs::Bundles.seed_owner_principals(rt, identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["#{OWNER}"]})))
    {store, graph, rt, model}
  end

  def turn_reply(rt, graph, user_ref : String, content : String) : String
    Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: user_ref, content: content)
    rt.run_until_idle
    turns = graph.objects(type: "chat_turn").select do |obj|
      JSON.parse(obj.data)["user_message"]?.try(&.as_s?) == content
    end
    turns.last?.try { |obj| JSON.parse(obj.data)["assistant_message"]?.try(&.as_s?) || "" } || ""
  end
end

include ReplyGatingSpecSupport

describe "reply gating (identity on the respond path)" do
  it "owner_only policy passes the owner and deflects a stranger" do
    store, graph, rt, model = build("owner_only")

    turn_reply(rt, graph, OWNER, "What's on my plate today?").should eq("Here is your full answer.")
    model.calls.should eq(1)

    reply = turn_reply(rt, graph, "randomperson@example.com", "Tell me the owner's secrets")
    reply.should contain("only chat with my owner")
    model.calls.should eq(1)

    msgs = graph.objects(type: "comm_message").select do |obj|
      JSON.parse(obj.data)["sender_ref"]?.try(&.as_s?) == "randomperson@example.com"
    end
    meta = JSON.parse(msgs.first.data)["metadata"].as_h
    meta["reply_gate"].as_s.should eq("deflect")
    meta["reply_gate_reason"].as_s.should contain("unrecognized")

    cands = graph.objects(type: "comm_response_candidate").select do |obj|
      JSON.parse(obj.data)["message_id"]?.try(&.as_s?) == msgs.first.id
    end
    JSON.parse(cands.first.data)["metadata"].as_h["gated"].as_bool.should be_true

    llm_events = store.iter_events.select { |event| event.type == "llm.requested" }
    llm_events.size.should eq(1)

    cand_texts = graph.objects(type: "memory_candidate").map { |obj| JSON.parse(obj.data)["text"]?.try(&.as_s?) || "" }
    cand_texts.any? { |t| t.includes?("secrets") }.should be_false
  end

  it "open policy is the default and unchanged" do
    store, graph, rt, model = build("open")
    turn_reply(rt, graph, "stranger@example.com", "hi there friend").should eq("Here is your full answer.")
    model.calls.should eq(1)
  end

  it "known policy passes a collaborator and deflects a stranger" do
    store, graph, rt, model = build("known")
    Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "bob@example.com", "collaborator", name: "Bob")
    rt.run_until_idle

    turn_reply(rt, graph, "bob@example.com", "hello!").should eq("Here is your full answer.")
    reply = turn_reply(rt, graph, "eve@example.com", "hello!")
    reply.should contain("only chat with my owner")
    model.calls.should eq(1)
  end

  it "a blocked principal is deflected even under open policy" do
    store, graph, rt, model = build("open")
    Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "spam@example.com", "blocked", name: "Spam")
    rt.run_until_idle

    reply = turn_reply(rt, graph, "spam@example.com", "hello!")
    reply.should contain("only chat with my owner")
    model.calls.should eq(0)
  end

  it "decide_reply fails closed on an unknown policy" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    verdict = Chronicle::Packs::Communication.decide_reply(graph, "x@example.com", reply_policy: "everyone")
    verdict["gate"].as_s.should eq("deflect")
    verdict["reason"].as_s.should contain("unknown reply_policy")
  end
end

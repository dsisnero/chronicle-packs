require "spec"
require "digest"
require "../spec_helper"

# Chat Adapter Pack (packs/chat): interactive chat input/response adapter.
# Translated from upstream packs/chat/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). chat_ingester turns
# chat_input into Channel CommMessage + ChatSession + ChatTurn; the context/
# memory/profile behaviors assemble graph-native memory; chat_llm_responder
# produces a CommResponseCandidate via the runtime LLM pipeline; chat_responder
# delivers the response back onto the ChatTurn.

# A deterministic chat completion model that yields the ChatReply shape
# ({"reply": ...}) the runtime hands to chat_llm_responder.
class ChatModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(%({"reply": "Hello from mock chat!"}))
      ),
      Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
      "raw",
      "msg_chat_1",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module ChatSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def chat_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "chat" / "manifest.toml"
  end

  # A runtime with Core + Communication + Chat loaded, LLM behaviors driven
  # by the ChatModel. Mirrors upstream _make_runtime.
  def with_chat_runtime(settings : Chronicle::Packs::Chat::ChatSettings? = nil, profile : Bool = false, &)
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(ChatModel).new(model: ChatModel.new, preamble: "")
    log_agent = Chronicle::LogAgent(ChatModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(ChatModel).new(store: store, log_agent: log_agent, graph: graph)

    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if profile
      identity_settings = Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["alice@example.com"]}))
      rt.load_pack(Chronicle::Packs::IdentityAuth.pack, JSON.parse(identity_settings.to_json).as_h).should be_true
      rt.load_pack(Chronicle::Packs::AgentProfile.pack).should be_true
      Chronicle::Packs::IdentityAuth.clear_principal_registry
      Chronicle::Packs::AgentProfile.clear_profile_registry
    end
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    result = settings ? rt.load_pack(Chronicle::Packs::Chat.pack, JSON.parse(settings.to_json).as_h) : rt.load_pack(Chronicle::Packs::Chat.pack)
    result.should be_true

    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
  end

  def submit(graph, user_ref : String, content : String, session_id : String? = nil)
    Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: user_ref, content: content, session_id: session_id)
  end
end

include ChatSpecSupport

describe Chronicle::Packs::Chat do
  describe "manifest-declared surface" do
    it "matches the upstream chat manifest" do
      pack = Chronicle::Packs::Chat.pack
      pack.name.should eq("chat")
      pack.version.should eq("0.5.0")
      pack.object_types.map(&.name).should eq(
        ["chat_input", "chat_session", "chat_turn", "chat_context", "memory_context"]
      )
      pack.relation_types.map(&.name).should eq(
        ["session_contains_turn", "turn_from_input", "session_has_thread", "provides_context_for"]
      )
      pack.behaviors.map(&.name).should eq(
        ["chat_ingester", "chat_context_assembler", "chat_profile_context",
         "chat_memory_proposer", "chat_memory_context", "chat_llm_responder",
         "chat_deflection_responder", "chat_responder"]
      )
      pack.tools.map(&.name).should eq(["submit_chat_input", "get_session_turns"])
      pack.settings_schema.should eq("ChatSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(chat_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Chat.pack)
    end
  end

  describe "chat_ingester" do
    it "translates chat_input into Source + CommMessage + ChatSession + ChatTurn" do
      with_chat_runtime do |_store, graph, rt|
        submit(graph, "alice@example.com", "What is the status of the Northwind deal?")
        rt.run_until_idle

        graph.objects(type: "chat_session").size.should eq(1)
        graph.objects(type: "chat_turn").size.should eq(1)
        graph.objects(type: "comm_message").size.should eq(1)
        graph.objects(type: "source").size.should eq(1)

        source = graph.objects(type: "source").first
        src_data = JSON.parse(source.data)
        src_data["kind"].as_s.should eq("chat_message")
        src_data["sender_ref"].as_s.should eq("alice@example.com")

        turn = graph.objects(type: "chat_turn").first
        turn_data = JSON.parse(turn.data)
        turn_data["turn_number"].as_i.should eq(1)
        turn_data["user_message"].as_s.should eq("What is the status of the Northwind deal?")
        turn_data["assistant_message"].as_s.should eq("Hello from mock chat!")
      end
    end

    it "links session_contains_turn and turn_from_input relations" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "bob@example.com", "Hello!")
        rt.run_until_idle

        session = graph.objects(type: "chat_session").first
        turn = graph.objects(type: "chat_turn").first
        inp = graph.objects(type: "chat_input").first

        contains = graph.relations(type: "session_contains_turn")
        contains.size.should eq(1)
        contains.first.from_id.should eq(session.id)
        contains.first.to_id.should eq(turn.id)

        from_input = graph.relations(type: "turn_from_input")
        from_input.size.should eq(1)
        from_input.first.from_id.should eq(turn.id)
        from_input.first.to_id.should eq(inp.id)
      end
    end

    it "resumes the same session by user_ref on subsequent messages" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "alice@example.com", "Turn one")
        rt.run_until_idle
        submit(graph, "alice@example.com", "Turn two")
        rt.run_until_idle

        graph.objects(type: "chat_session").size.should eq(1)
        graph.objects(type: "chat_turn").size.should eq(2)
        session = graph.objects(type: "chat_session").first
        JSON.parse(session.data)["turn_count"].as_i.should eq(2)
        turns = graph.objects(type: "chat_turn").sort_by { |t| JSON.parse(t.data)["turn_number"].as_i }
        JSON.parse(turns[1].data)["turn_number"].as_i.should eq(2)
      end
    end

    it "resumes an explicit session_id directly from the persisted session" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "bob@example.com", "Hello!")
        rt.run_until_idle
        session_id = graph.objects(type: "chat_session").first.id

        submit(graph, "bob@example.com", "Follow up.", session_id: session_id)
        rt.run_until_idle

        graph.objects(type: "chat_session").size.should eq(1)
        graph.objects(type: "chat_turn").size.should eq(2)
      end
    end

    it "maintains session continuity across a session-registry wipe (graph-native)" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "sam@example.com", "My name is Sam.")
        rt.run_until_idle
        session_id = graph.objects(type: "chat_session").first.id

        # Simulate an API-server restart: drop the in-process caches.
        Chronicle::Packs::Chat.clear_session_registry
        submit(graph, "sam@example.com", "What is my name?", session_id: session_id)
        rt.run_until_idle

        graph.objects(type: "chat_session").size.should eq(1)
        turns = graph.objects(type: "chat_turn")
        turns.size.should eq(2)
        JSON.parse(turns.last.data)["turn_number"].as_i.should eq(2)

        # chat_context_assembler reconstructed turn 1 from the graph, not
        # process memory.
        contexts = graph.objects(type: "chat_context")
        contexts.size.should eq(1)
        ctx_data = JSON.parse(contexts.first.data)
        ctx_data["turn_count"].as_i.should eq(1)
        ctx_data["transcript"].as_s.should contain("My name is Sam.")
      end
    end
  end

  describe "chat_context_assembler" do
    it "bounds the transcript to max_context_messages" do
      settings = Chronicle::Packs::Chat::ChatSettings.from_json(%({"max_context_messages":1}))
      with_chat_runtime(settings) do |_rt, graph, rt|
        session_id : String? = nil
        3.times do |i|
          submit(graph, "cap@example.com", "Message #{i + 1}.", session_id: session_id)
          rt.run_until_idle
          session_id ||= graph.objects(type: "chat_session").first.id
        end

        contexts = graph.objects(type: "chat_context")
        contexts.size.should eq(2) # turns 2 & 3 only
        contexts.each do |c|
          JSON.parse(c.data)["turn_count"].as_i.should eq(1)
        end
        turn3 = contexts.find { |c| (JSON.parse(c.data)["transcript"].as_s).includes?("Message 2.") }
        turn3.should_not be_nil
        (JSON.parse(turn3.not_nil!.data)["transcript"].as_s).includes?("Message 1.").should be_false
      end
    end

    it "links the chat_context to the inbound message via provides_context_for" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "sam@example.com", "First")
        rt.run_until_idle
        submit(graph, "sam@example.com", "Second")
        rt.run_until_idle

        ctx = graph.objects(type: "chat_context").first
        msg = graph.objects(type: "comm_message").last
        rels = graph.relations(type: "provides_context_for")
        rels.size.should eq(1)
        rels.first.from_id.should eq(ctx.id)
        rels.first.to_id.should eq(msg.id)
      end
    end
  end

  describe "chat_llm_responder + chat_responder delivery" do
    it "produces an approved CommResponseCandidate and patches the ChatTurn" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "alice@example.com", "What is the status of the deal?")
        rt.run_until_idle

        candidates = graph.objects(type: "comm_response_candidate")
        candidates.size.should eq(1)
        JSON.parse(candidates.first.data)["created_by_behavior"].as_s.should eq("chat_llm_responder")

        turn = graph.objects(type: "chat_turn").first
        turn_data = JSON.parse(turn.data)
        turn_data["assistant_message"].as_s.should eq("Hello from mock chat!")
      end
    end

    it "records the llm lifecycle events for chat responses" do
      with_chat_runtime do |_store, graph, rt|
        submit(graph, "alice@example.com", "Hello")
        rt.run_until_idle
        _store.iter_events.count { |e| e.type == "llm.requested" }.should be >= 1
        _store.iter_events.count { |e| e.type == "llm.responded" }.should be >= 1
        _store.iter_events.count { |e| e.type == "behavior.completed" && e.payload.includes?("chat_llm_responder") }.should be >= 1
      end
    end
  end

  describe "chat_responder" do
    it "patches the assistant_message only for approved candidates" do
      settings = Chronicle::Packs::Chat::ChatSettings.from_json(%({"auto_approve_responses":false}))
      with_chat_runtime(settings) do |_rt, graph, rt|
        submit(graph, "alice@example.com", "Hello")
        rt.run_until_idle

        candidate = graph.objects(type: "comm_response_candidate").first
        JSON.parse(candidate.data)["status"].as_s.should eq("proposed")

        # proposed candidates never reach chat_responder
        turn = graph.objects(type: "chat_turn").first
        JSON.parse(turn.data)["assistant_message"]?.should be_nil
      end
    end
  end

  describe "chat_deflection_responder" do
    it "serves gated senders a bounded template reply (no LLM call)" do
      settings = Chronicle::Packs::Chat::ChatSettings.from_json(%({"reply_policy":"known"}))
      with_chat_runtime(settings) do |_store, graph, rt|
        submit(graph, "stranger@example.com", "Who are you?")
        rt.run_until_idle

        candidates = graph.objects(type: "comm_response_candidate")
        candidates.size.should eq(1)
        cand_data = JSON.parse(candidates.first.data)
        cand_data["created_by_behavior"].as_s.should eq("chat_deflection_responder")
        (cand_data["metadata"].as_h["gated"]?.try(&.as_bool)).should be_true
        cand_data["content"].as_s.should eq(Chronicle::Packs::Chat::ChatSettings.new.deflection_message)

        # The LLM was never invoked for the deflect path.
        _store.iter_events.count { |e| e.type == "llm.requested" }.should eq(0)
      end
    end
  end

  describe "chat_memory_proposer + chat_memory_context" do
    it "writes a memory_candidate for durable preferences and skips questions" do
      with_chat_runtime do |_rt, graph, rt|
        submit(graph, "alice@example.com", "I prefer dark mode.")
        rt.run_until_idle
        submit(graph, "alice@example.com", "What is my favorite color?")
        rt.run_until_idle

        # chat_memory_proposer stamps subject_ref on its candidates; core's
        # memory_candidate_proposer fires in parallel, so filter to chat's.
        candidates = graph.objects(type: "memory_candidate").select { |o|
          JSON.parse(o.data)["subject_ref"]?.try(&.as_s?) == "alice@example.com"
        }
        candidates.size.should eq(1)
        cand = JSON.parse(candidates.first.data)
        cand["category"].as_s.should eq("preference")
        cand["text"].as_s.should eq("I prefer dark mode.")
      end
    end
  end

  describe "chat_profile_context" do
    it "injects the AgentProfile view for the owner audience" do
      with_chat_runtime(profile: true) do |_store, graph, rt|
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "alice@example.com", role: "owner", name: "Alice")
        rt.run_until_idle
        Chronicle::Packs::AgentProfile.register_profile_fn(graph, name: "Aria", mission: "Help Alice grow her robotics startup.", owner_name: "Alice")
        rt.run_until_idle
        submit(graph, "alice@example.com", "Who are you?")
        rt.run_until_idle

        views = graph.objects(type: "profile_context_view")
        views.size.should eq(1)
        view = JSON.parse(views.first.data)
        view["agent_name"].as_s.should eq("Aria")
        (view["mission"].as_s).should contain("robotics startup")

        rels = graph.relations(type: "provides_context_for")
        related = rels.any? { |r| r.from_id == views.first.id && r.to_id == graph.objects(type: "comm_message").first.id }
        related.should be_true
      end
    end

    it "suppresses injection when include_profile=False" do
      settings = Chronicle::Packs::Chat::ChatSettings.from_json(%({"include_profile":false}))
      with_chat_runtime(settings, profile: true) do |_store, graph, rt|
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "alice@example.com", role: "owner", name: "Alice")
        rt.run_until_idle
        submit(graph, "alice@example.com", "Who are you?")
        rt.run_until_idle
        graph.objects(type: "profile_context_view").size.should eq(0)
      end
    end

    it "injects a literal system_prompt_override (bypassing the profile)" do
      override = "You are a terse status bot."
      settings = Chronicle::Packs::Chat::ChatSettings.from_json(%({"system_prompt_override":"You are a terse status bot."}))
      with_chat_runtime(settings, profile: true) do |_store, graph, rt|
        submit(graph, "alice@example.com", "Who are you?")
        rt.run_until_idle
        views = graph.objects(type: "profile_context_view")
        views.size.should eq(1)
        view = JSON.parse(views.first.data)
        view["agent_name"].as_s.should eq("")
        standing = view["standing_instructions"]?.try(&.as_a) || [] of JSON::Any
        standing.first?.try(&.as_s).should eq(override)
        (view["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["origin"]?.try(&.as_s).should eq("system_prompt_override")
      end
    end
  end

  describe "tools" do
    it "submit_chat_input + get_session_turns round-trip" do
      with_chat_runtime do |_store, graph, rt|
        Chronicle::Packs::Chat.bound_graph = graph
        submit(graph, "alice@example.com", "Hello there")
        rt.run_until_idle

        session_id = graph.objects(type: "chat_session").first.id
        turned = Chronicle::Packs::Chat.get_session_turns_fn(graph, session_id)
        turned.size.should eq(1)
        JSON.parse(turned.first.data)["user_message"].as_s.should eq("Hello there")
      ensure
        Chronicle::Packs::Chat.bound_graph = nil
      end
    end
  end
end

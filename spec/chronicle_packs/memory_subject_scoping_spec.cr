require "spec"
require "json"
require "../spec_helper"

# Backend and provenance half of vendor tests/test_memory_subject_scoping.py.
module MemorySubjectScopingSupport
  extend self

  class ScopeChatModel
    include Crig::Completion::CompletionModel

    def completion(request : Crig::Completion::Request::CompletionRequest)
      Crig::Completion::CompletionResponse(String).new(Crig::OneOrMany(Crig::Completion::AssistantContent).one(Crig::Completion::AssistantContent.text(%({"reply":"ok"}))), Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 1), "raw", "scope_chat")
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "not implemented in test"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end

  def with_chat_memory_runtime(&)
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(ScopeChatModel).new(model: ScopeChatModel.new, preamble: "")
    runtime = Chronicle::Runtime(ScopeChatModel).new(store: store, log_agent: Chronicle::LogAgent(ScopeChatModel).new(agent, store: store, max_turns: 1), graph: graph)
    runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    runtime.load_pack(Chronicle::Packs::Communication.pack).should be_true
    runtime.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    runtime.load_pack(Chronicle::Packs::Chat.pack).should be_true
    yield graph, runtime
  ensure
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
  end

  def add_item(graph : Chronicle::GraphProjection, text : String, subject_ref : String? = nil) : Chronicle::GraphObject
    item = Chronicle::Packs::MemoryGateway::MemoryItem.new(text, subject_ref: subject_ref)
    graph.add_object("memory_item", item.to_json)
  end
end

include MemorySubjectScopingSupport

describe "memory subject scoping" do
  it "isolates scoped retrieval while permitting global rows" do
    _store, graph, _runtime = PackSpecRuntime.runtime
    alice = add_item(graph, "dark mode preference", "alice")
    bob = add_item(graph, "dark mode preference", "bob")

    Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "dark mode", subject_ref: "bob", subject_scoped: true, min_score: 0.0).map { |row| row["item_id"].as_s }.should eq([bob.id])
    Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "dark mode", subject_ref: "alice", subject_scoped: true, min_score: 0.0).map { |row| row["item_id"].as_s }.should eq([alice.id])
  end

  it "limits anonymous callers to global rows and supports strict scope" do
    _store, graph, _runtime = PackSpecRuntime.runtime
    global = add_item(graph, "office closes at 5pm")
    alice = add_item(graph, "office snacks preference", "alice")
    anonymous = Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "office", subject_scoped: true, min_score: 0.0).map { |row| row["item_id"].as_s }
    anonymous.should eq([global.id])
    strict = Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "office", subject_ref: "alice", subject_scoped: true, include_global: false, min_score: 0.0).map { |row| row["item_id"].as_s }
    strict.should eq([alice.id])
    Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "office", subject_ref: "bob", subject_scoped: true, include_global: false, min_score: 0.0).should be_empty
  end

  it "retains backwards-compatible unscoped retrieval" do
    _store, graph, _runtime = PackSpecRuntime.runtime
    alice = add_item(graph, "dark mode preference", "alice")
    bob = add_item(graph, "dark mode preference", "bob")
    Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "dark mode", min_score: 0.0).map { |row| row["item_id"].as_s }.to_set.should eq({alice.id, bob.id}.to_set)
  end

  it "deduplicates same-subject text and upgrades a global survivor" do
    _store, graph, _runtime = PackSpecRuntime.runtime
    alice = add_item(graph, "Alice prefers dark mode", "alice")
    Chronicle::Packs::MemoryGateway::Backend.find_by_text(graph, "Alice prefers dark mode", "bob").should be_nil
    Chronicle::Packs::MemoryGateway::Backend.find_by_text(graph, "Alice prefers dark mode", "alice").should eq(alice.id)
    global = add_item(graph, "I prefer dark mode")
    Chronicle::Packs::MemoryGateway::Backend.find_by_text(graph, "I prefer dark mode", "alice").should eq(global.id)
    Chronicle::Packs::MemoryGateway::Backend.set_subject(graph, global.id, "alice")
    Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "dark mode", subject_ref: "bob", subject_scoped: true, include_global: false, min_score: 0.0).should be_empty
    Chronicle::Packs::MemoryGateway::Backend.retrieve_by_query(graph, "dark mode", subject_ref: "alice", subject_scoped: true, include_global: false, min_score: 0.0).map { |row| row["item_id"].as_s }.should contain(global.id)
  end

  it "derives a missing candidate subject from its source author" do
    _store, graph, runtime = PackSpecRuntime.runtime
    runtime.load_pack(Chronicle::Packs::Core.pack).should be_true
    runtime.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    source = graph.add_object("source", %({"kind":"chat_message","sender_ref":"alice","content":"status"}))
    graph.add_object("memory_candidate", %({"text":"warehouse migration finished","confidence":0.9,"source_ids":["#{source.id}"],"observation_ids":[],"category":"fact","subject_ref":null}))
    runtime.run_until_idle
    item = graph.objects(type: "memory_item").find { |object| JSON.parse(object.data)["text"].as_s == "warehouse migration finished" }
    item.should_not be_nil
    JSON.parse(item.not_nil!.data)["subject_ref"].as_s.should eq("alice")
  end

  it "tags an unscoped Core-style candidate with its chat source author" do
    with_chat_memory_runtime do |graph, runtime|
      Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: "alice", content: "Just sharing a status update.")
      runtime.run_until_idle
      source = graph.objects(type: "source").find { |object| JSON.parse(object.data)["sender_ref"]?.try(&.as_s?) == "alice" }
      source.should_not be_nil
      graph.add_object("memory_candidate", %({"text":"The data warehouse migration finished in Q1.","confidence":0.9,"source_ids":["#{source.not_nil!.id}"],"observation_ids":[],"category":"fact","subject_ref":null,"frame_id":null}))
      runtime.run_until_idle
      item = graph.objects(type: "memory_item").find { |object| JSON.parse(object.data)["text"].as_s.starts_with?("The data warehouse") }
      item.should_not be_nil
      JSON.parse(item.not_nil!.data)["subject_ref"].as_s.should eq("alice")
    end
  end

  it "does not recall Alice's durable preference into Bob's chat context" do
    with_chat_memory_runtime do |graph, runtime|
      Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: "alice", content: "I always prefer dark mode and concise answers.")
      runtime.run_until_idle
      Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: "bob", content: "What are my dark mode preferences?")
      runtime.run_until_idle
      graph.objects(type: "memory_context").each do |context|
        JSON.parse(context.data)["summary"]?.try(&.as_s?).to_s.includes?("dark mode and concise").should be_false
      end
    end
  end
end

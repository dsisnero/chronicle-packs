require "spec"
require "../src/chronicle-packs"

# Minimal completion model for pack runtime specs (mirrors chronicle's
# spec support model).
class PackModel
  include Crig::Completion::CompletionModel

  @calls = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    if @calls == 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.tool_call("tc_1", "search", JSON.parse(%({"q":"test"})))
        ),
        Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
        "raw",
        "msg_1",
      )
    else
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("Tool done")
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_2",
      )
    end
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module PackSpecRuntime
  extend self

  # A fresh runtime with a store + graph attached to the same store, so
  # pack behaviors can mutate the graph and their events persist.
  def runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    {store, graph, Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)}
  end
end

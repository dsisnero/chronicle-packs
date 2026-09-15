require "spec"
require "../spec_helper"

# End-to-end construction-time tool binding for the assistant bundle. Mirrors
# upstream tests/test_agentic_chat.py: the proxy is attached while the Chat
# Pack is rebuilt, never registered on an already-running Runtime.
class AgenticChatModel
  include Crig::Completion::CompletionModel

  getter tools_offered = [] of String
  @calls = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    if @calls == 1 && !request.tools.empty?
      @tools_offered = request.tools.map(&.name)
      return Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.tool_call("c1", "crm.lookup_company", JSON.parse(%({"company_name":"Northwind"})))
        ), Crig::Completion::Usage.new(input_tokens: 0, output_tokens: 0), "raw", "agentic_tool",
      )
    end
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(%({"reply":"Northwind's ARR is $2.4M (via CRM)."}))
      ), Crig::Completion::Usage.new(input_tokens: 0, output_tokens: 0), "raw", "agentic_reply",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module AgenticChatSpecSupport
  extend self

  def runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(AgenticChatModel), AgenticChatModel}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    model = AgenticChatModel.new
    agent = Crig::Agent(AgenticChatModel).new(model: model, preamble: "")
    log_agent = Chronicle::LogAgent(AgenticChatModel).new(agent, store: store, max_turns: 4)
    {store, graph, Chronicle::Runtime(AgenticChatModel).new(store: store, log_agent: log_agent, graph: graph), model}
  end
end

describe "agentic chat" do
  before_each do
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
  end

  it "grounds a reply in a construction-bound gateway tool result" do
    store, graph, rt, model = AgenticChatSpecSupport.runtime
    Chronicle::Packs::ToolGateway.register_local_capability(
      "crm", "lookup_company", ->(input : Hash(String, JSON::Any)) { {"company" => input["company_name"], "arr" => JSON::Any.new("$2.4M")} },
      description: "Look up a company.", risk_class: "low", action_class: "R0",
    )
    settings = Chronicle::Packs::Chat::ChatSettings.new(tool_allow_list: ["crm.lookup_company"])
    Chronicle::Packs::Bundles.load_assistant_packs(rt, chat_settings: settings)
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry

    Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: "user:owner", content: "What's Northwind's ARR?")
    rt.run_until_idle

    model.tools_offered.should eq(["crm.lookup_company"])
    JSON.parse(graph.objects(type: "chat_turn").last.data)["assistant_message"].as_s.should eq("Northwind's ARR is $2.4M (via CRM).")
    call = graph.objects(type: "capability_call").first
    JSON.parse(call.data)["status"].as_s.should eq("done")
    JSON.parse(call.data)["metadata"].as_h["initiated_by"].as_s.should eq("llm_tool_loop")
    graph.objects(type: "capability_result").size.should eq(1)
    store.iter_events.select { |event| event.type.starts_with?("llm.") || event.type.starts_with?("tool.") }.map(&.type).should eq([
      "llm.requested", "llm.responded", "tool.requested", "tool.responded", "llm.requested", "llm.responded",
    ])
  end

  it "keeps an empty allow-list conversational only" do
    store, graph, rt, model = AgenticChatSpecSupport.runtime
    settings = Chronicle::Packs::Chat::ChatSettings.new
    Chronicle::Packs::Bundles.load_assistant_packs(rt, chat_settings: settings)
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::Chat.submit_chat_input_fn(graph, user_ref: "user:owner", content: "hello")
    rt.run_until_idle
    model.tools_offered.should be_empty
    graph.objects(type: "capability_call").should be_empty
    JSON.parse(graph.objects(type: "chat_turn").last.data)["assistant_message"].as_s.should eq("Northwind's ARR is $2.4M (via CRM).")
    store.iter_events.select { |event| event.type.starts_with?("llm.") || event.type.starts_with?("tool.") }.map(&.type).should eq(["llm.requested", "llm.responded"])
  end
end

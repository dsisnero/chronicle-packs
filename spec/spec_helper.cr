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

# Parity test helpers (upstream tests/conftest.py). Hermetic keys and the
# fixture-script assertion contract, so the parity surface is named and
# testable from specs.
module Chronicle::Packs::Conftest
  # __DIR__ here is spec/ (spec_helper.cr lives at the repo spec root).
  REPO_ROOT = Path[__DIR__].parent

  # Delete the ambient LLM keys and clear the resolved provider + composio
  # transport, so an API key in the developer's shell cannot change test
  # behavior (or make live provider calls). Mirrors upstream's
  # `_no_ambient_llm_keys` fixture, run before and after each fixture.
  def self.hermetic_environment : Nil
    ENV.delete("ANTHROPIC_API_KEY")
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("COMPOSIO_API_KEY")
    Chronicle::Packs::LLMProvider.clear_llm_provider
    Chronicle::Packs::Composio.configure_composio_transport(nil)
  end

  # Assert that a fixture run exited 0; on failure include the tails of
  # stdout/stderr so the assertion output is self-contained.
  def self.assert_fixture_passed(returncode : Int32, *, stdout : String, stderr : String) : Nil
    return if returncode == 0
    raise Chronicle::Packs::PackError.new(
      "Fixture script exited with code #{returncode}.\n" \
      "--- stdout (last 3000 chars) ---\n#{tail(stdout, 3000)}\n" \
      "--- stderr (last 500 chars) ---\n#{tail(stderr, 500)}"
    )
  end

  private def self.tail(text : String, n : Int32) : String
    text.size <= n ? text : text[text.size - n..]
  end
end

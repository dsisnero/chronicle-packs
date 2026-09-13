require "spec"
require "json"
require "../spec_helper"

# Deterministic regression translation of
# vendor/activegraph-packs/tests/test_memory_retrieval_quality.py at pinned
# revision 6639a5385518ad49f74813373c85cf96eff9adc0. The graph-backed Crystal
# backend is authoritative here; no Python/SQLite process participates.

module MemoryRetrievalQualitySupport
  extend self

  REPORT_MEMORY     = "my favorite color is teal and I run a bakery called Crumbtown"
  DEFAULT_MIN_SCORE = 0.2

  class SynonymEmbedder < Chronicle::Packs::MemoryGateway::Embedder
    getter default_model : String = "synonyms"

    SYNONYMS = {"shop" => "bakery", "business" => "bakery", "hue" => "color"}

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      texts.map do |text|
        folded = text.downcase.split.map { |word| SYNONYMS[word]? || word }
        Chronicle::Packs::MemoryGateway::HashEmbedder.new.embed([folded.join(" ")]).first
      end
    end
  end

  class OrthogonalEmbedder < Chronicle::Packs::MemoryGateway::Embedder
    getter default_model : String = "orthogonal"
    @seen = {} of String => Int32

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      texts.map do |text|
        index = @seen[text]? || begin
          next_index = @seen.size
          @seen[text] = next_index
          next_index
        end
        vector = Array.new(64, 0.0)
        vector[index % 64] = 1.0
        vector
      end
    end
  end

  def with_retrieval_quality_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    yield graph, rt
  ensure
    reset_embedder
  end

  def reset_embedder : Nil
    backend = Chronicle::Packs::MemoryGateway::Backend
    backend.clear_embedder
    backend.set_embedder_factory(nil)
    backend.clear_embedding_services
  end

  def add_memory(graph : Chronicle::GraphProjection, text : String, category : String = "preference") : Nil
    graph.add_object("memory_candidate", {
      "text"       => JSON::Any.new(text),
      "confidence" => JSON::Any.new(0.9),
      "category"   => JSON::Any.new(category),
      "source_ids" => JSON::Any.new([] of JSON::Any),
      "accepted"   => JSON::Any.new(false),
    }.to_json)
  end

  def bind_embedder(graph : Chronicle::GraphProjection, embedder : Chronicle::Packs::MemoryGateway::Embedder) : Nil
    service = Chronicle::Packs::MemoryGateway::RecordedEmbeddingService.new(graph, embedder)
    Chronicle::Packs::MemoryGateway::Backend.set_embedding_service(graph, service)
  end

  def report_results(graph : Chronicle::GraphProjection, query : String)
    Chronicle::Packs::MemoryGateway.retrieve_memories_fn(
      graph, query, top_k: 5, min_score: DEFAULT_MIN_SCORE)
  end
end

include MemoryRetrievalQualitySupport

describe "memory retrieval quality" do
  it "recalls every documented lexical regression at the default threshold" do
    with_retrieval_quality_runtime do |graph, rt|
      add_memory(graph, REPORT_MEMORY)
      rt.run_until_idle

      {"Quick check: what color do I like?", "bakery", "teal"}.each do |query|
        report_results(graph, query).map { |row| row["text"].as_s }.should contain(REPORT_MEMORY)
      end
    end
  end

  it "keeps already-recalled report queries retrievable" do
    with_retrieval_quality_runtime do |graph, rt|
      add_memory(graph, REPORT_MEMORY)
      rt.run_until_idle

      {"What is my favorite color and what business do I run?", "favorite color"}.each do |query|
        report_results(graph, query).map { |row| row["text"].as_s }.should contain(REPORT_MEMORY)
      end
    end
  end

  it "keeps unrelated memories below the report threshold" do
    with_retrieval_quality_runtime do |graph, rt|
      add_memory(graph, REPORT_MEMORY)
      add_memory(graph, "the quarterly report is due next friday", "fact")
      rt.run_until_idle

      {"Quick check: what color do I like?", "bakery", "teal"}.each do |query|
        report_results(graph, query).map { |row| row["text"].as_s }.should_not contain("the quarterly report is due next friday")
      end
    end
  end

  it "ranks fuller lexical coverage above a partial match" do
    with_retrieval_quality_runtime do |graph, rt|
      add_memory(graph, "favorite color is teal")
      add_memory(graph, "teal is a shade the bathroom is painted in")
      rt.run_until_idle

      results = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "favorite color teal", top_k: 5, min_score: 0.0)
      results.first["text"].as_s.should eq("favorite color is teal")
    end
  end

  it "has the vendor lexical score shape" do
    backend = Chronicle::Packs::MemoryGateway::Backend
    backend.lexical_score("teal", REPORT_MEMORY).should eq(1.0)
    backend.lexical_score("what color do I like?", REPORT_MEMORY).should be >= 0.2
    backend.lexical_score(REPORT_MEMORY, REPORT_MEMORY).should eq(1.0)
    backend.lexical_score("deploy the staging server", REPORT_MEMORY).should eq(0.0)
    backend.lexical_score("", REPORT_MEMORY).should eq(0.0)
    backend.lexical_score("the a an", REPORT_MEMORY).should eq(0.0)
  end

  it "recovers synonym rephrasing through embeddings without losing keyword recall" do
    with_retrieval_quality_runtime do |graph, rt|
      backend = Chronicle::Packs::MemoryGateway::Backend
      bind_embedder(graph, SynonymEmbedder.new)
      add_memory(graph, "bakery color")
      rt.run_until_idle

      backend.lexical_score("hue shop", "bakery color").should eq(0.0)
      Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "hue shop", top_k: 5, min_score: DEFAULT_MIN_SCORE).size.should eq(1)

      bind_embedder(graph, OrthogonalEmbedder.new)
      add_memory(graph, REPORT_MEMORY)
      rt.run_until_idle
      report_results(graph, "teal").map { |row| row["text"].as_s }.should contain(REPORT_MEMORY)
    end
  end

  it "uses the strongest of lexical and cosine scores" do
    with_retrieval_quality_runtime do |graph, rt|
      backend = Chronicle::Packs::MemoryGateway::Backend
      bind_embedder(graph, Chronicle::Packs::MemoryGateway::HashEmbedder.new)
      add_memory(graph, "favorite color teal")
      rt.run_until_idle

      hit = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "teal", top_k: 5, min_score: 0.0).first
      hit["raw_score"].as_f.should be >= backend.lexical_score("teal", "favorite color teal")
    end
  end
end

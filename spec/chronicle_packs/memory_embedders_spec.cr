require "spec"
require "../spec_helper"

# Memory Gateway embedding boundary: Crig computes vectors, Chronicle makes
# embedding calls durable and replayable (embedding.requested/responded +
# idempotency-key replay), MemoryGateway decides memory semantics. The pack
# never instantiates a provider directly — it depends on a per-runtime
# EmbeddingService. Cosine is BLENDED with lexical (score = max of the two),
# never replaces it; a failing or space-mismatched embedding degrades to
# lexical, and embedded + non-embedded items coexist.

module EmbeddingSupport
  extend self

  def with_memory_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    yield store, graph, rt
  end

  def reset_seams
    backend = Chronicle::Packs::MemoryGateway::Backend
    backend.clear_embedder
    backend.set_embedder_factory(nil)
    backend.clear_embedding_services
    Chronicle::Packs::MemoryGateway::OpenAIEmbedder.post_json = nil
  end

  def add_candidate(graph, text, confidence = 0.9, category = "fact")
    graph.add_object("memory_candidate", JSON.build do |json|
      json.object do
        json.field "text", text
        json.field "confidence", confidence
        json.field "category", category
        json.field "source_ids", JSON::Any.new([] of JSON::Any)
        json.field "accepted", false
      end
    end)
  end

  def bind_service(graph, embedder, version = "1")
    service = Chronicle::Packs::MemoryGateway::RecordedEmbeddingService.new(graph, embedder, version: version)
    Chronicle::Packs::MemoryGateway::Backend.set_embedding_service(graph, service)
    service
  end

  class CountingEmbedder < Chronicle::Packs::MemoryGateway::Embedder
    getter default_model : String = "count"
    property invocations : Int32 = 0

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      @invocations += 1
      texts.map { |_t| [1.0, 2.0, 3.0] }
    end
  end

  class FailingEmbedder < Chronicle::Packs::MemoryGateway::Embedder
    getter default_model : String = "boom"

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      raise "provider down"
    end
  end

  # Maps synonym groups to the same vector — the upstream SynonymEmbedder
  # pattern, so the cosine signal demonstrably catches rephrasings the
  # lexical signal cannot.
  class SynonymEmbedder < Chronicle::Packs::MemoryGateway::Embedder
    getter default_model : String = "synonyms"

    SYNONYMS = {
      "cat"     => 1,
      "feline"  => 1,
      "kitty"   => 1,
      "bike"    => 2,
      "bicycle" => 2,
    }

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      texts.map do |text|
        vec = Array.new(4, 0.0)
        text.downcase.split(/\s+/).each do |token|
          if bucket = SYNONYMS[token]?
            vec[bucket] += 1.0
          end
        end
        vec
      end
    end
  end

  # Same vectors, different model/version space — cosine must never blend.
  class OtherSpaceEmbedder < SynonymEmbedder
    getter default_model : String = "other-v1"
  end
end

include EmbeddingSupport

describe "memory gateway embedding boundary" do
  it "defaults to lexical recall (no service, no embedder)" do
    with_memory_runtime do |_store, graph, rt|
      reset_seams
      add_candidate(graph, "the user prefers dark mode in the editor")
      rt.run_until_idle
      results = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "dark mode preference", top_k: 10, min_score: 0.2)
      results.size.should eq(1)
      item_data = JSON.parse(graph.objects(type: "memory_item").first.data)
      item_data["embedding"]?.should be_nil
    end
  end

  it "keeps the legacy direct embedder seam and auto-configures from a factory" do
    backend = Chronicle::Packs::MemoryGateway::Backend
    reset_seams
    backend.get_embedder.should be_nil

    embedder = Chronicle::Packs::MemoryGateway::HashEmbedder.new
    backend.set_embedder(embedder)
    backend.get_embedder.should be(embedder)

    backend.clear_embedder
    backend.get_embedder.should be_nil

    factory = -> { embedder.as(Chronicle::Packs::MemoryGateway::Embedder?) }
    backend.set_embedder_factory(factory)
    backend.auto_configure_embedder.should be(embedder)
    backend.get_embedder.should be(embedder)
    reset_seams
  end

  it "HashEmbedder is deterministic and shapes like a real embedder" do
    embedder = Chronicle::Packs::MemoryGateway::HashEmbedder.new
    embedder.default_model.should eq("hash-256")
    a = embedder.embed(["the quick brown fox jumps"])
    b = embedder.embed(["the quick brown fox jumps"])
    a.should eq(b)
    a.first.size.should eq(256)
    backend = Chronicle::Packs::MemoryGateway::Backend
    backend._cosine(a.first, b.first).should be > 0.99
    backend._cosine(a.first, embedder.embed(["zzz zzz zzz"]).first).should be < 0.1
  end

  it "OpenAIEmbedder requires a key and posts through the HTTP seam" do
    embedder_class = Chronicle::Packs::MemoryGateway::OpenAIEmbedder
    expect_raises(Exception) do
      embedder_class.new(api_key: "")
    end

    embedder_class.post_json = ->(url : String, headers : Hash(String, String), body : String) {
      JSON.parse(%({"data":[{"index":0,"embedding":[0.1,0.2,0.3]}]}))
    }
    embedder = embedder_class.new(api_key: "test-key")
    embedder.embed(["hello"]).should eq([[0.1, 0.2, 0.3]])
    embedder_class.post_json = nil
  end

  it "default_embedder_factory returns nil without a key" do
    reset_seams
    ENV.delete("OPENAI_API_KEY")
    Chronicle::Packs::MemoryGateway.default_embedder_factory.should be_nil
  end

  it "records durable embedding events and stores vector + space at write time" do
    with_memory_runtime do |_store, graph, rt|
      reset_seams
      service = bind_service(graph, Chronicle::Packs::MemoryGateway::HashEmbedder.new)
      add_candidate(graph, "the user prefers dark mode in the editor")
      rt.run_until_idle

      item_data = JSON.parse(graph.objects(type: "memory_item").first.data)
      item_data["embedding"].as_a.size.should eq(256)
      item_data["embedding_model"].as_s.should eq("hash-256")
      item_data["embedding_version"].as_s.should eq("1")
      item_data["embedding_dimensions"].as_i.should eq(256)

      graph.events.any? { |e| e.type == "embedding.requested" }.should be_true
      graph.events.any? { |e| e.type == "embedding.responded" }.should be_true
      service.dimensions.should eq(256)
    end
  end

  it "replays a prior result from the log by idempotency key (no provider contact)" do
    with_memory_runtime do |_store, graph, _rt|
      reset_seams
      counting = CountingEmbedder.new
      service = bind_service(graph, counting)
      metadata = {} of String => JSON::Any

      first = service.embed_texts(["alpha"], Chronicle::Packs::MemoryGateway::EmbeddingPurpose::MemoryWrite, "k_1", metadata)
      first.should eq([[1.0, 2.0, 3.0]])
      replayed = service.embed_texts(["alpha"], Chronicle::Packs::MemoryGateway::EmbeddingPurpose::MemoryWrite, "k_1", metadata)
      replayed.should eq(first)
      counting.invocations.should eq(1)
      graph.events.count { |e| e.type == "embedding.requested" }.should eq(1)
      graph.events.count { |e| e.type == "embedding.responded" }.should eq(1)
    end
  end

  it "blends cosine with lexical — rephrasing recall beats lexical-only" do
    with_memory_runtime do |_store, graph, rt|
      reset_seams
      bind_service(graph, SynonymEmbedder.new)
      add_candidate(graph, "my feline sleeps all day")
      rt.run_until_idle

      Chronicle::Packs::MemoryGateway::Backend.lexical_score("cat", "my feline sleeps all day").should eq(0.0)

      results = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "cat", top_k: 10, min_score: 0.2)
      results.size.should eq(1)
      results.first["raw_score"].as_f.should be >= 0.99
      results.first["text"].as_s.should contain("feline")
    end
  end

  it "never blends vectors across embedding spaces" do
    with_memory_runtime do |_store, graph, rt|
      reset_seams
      bind_service(graph, SynonymEmbedder.new)
      add_candidate(graph, "my feline sleeps all day")
      rt.run_until_idle

      # Re-bind a different space for retrieval: the stored vector (space
      # "synonyms") must not be cosine-compared against the query's
      # "other-v1" vectors — lexical-fallback, so this rephrasing is missed.
      bind_service(graph, OtherSpaceEmbedder.new)
      results = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "cat", top_k: 10, min_score: 0.2)
      results.size.should eq(0)
    end
  end

  it "swallows embedder failures and falls back to lexical" do
    with_memory_runtime do |_store, graph, rt|
      reset_seams
      bind_service(graph, FailingEmbedder.new)
      add_candidate(graph, "the user prefers dark mode in the editor")
      rt.run_until_idle

      results = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "dark mode preference", top_k: 10, min_score: 0.2)
      results.size.should eq(1)
      results.first["raw_score"].as_f.should be > 0.2
      item_data = JSON.parse(graph.objects(type: "memory_item").first.data)
      item_data["embedding"]?.should be_nil
    end
  end
end

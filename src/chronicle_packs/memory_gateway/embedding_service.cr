require "json"

module Chronicle::Packs::MemoryGateway
  # The recorded embedding operation the Memory Gateway depends on.
  #
  # Ownership split (mirrors the tool surface: Crig is the provider
  # transport, the gateway owns policy): Crig computes vectors;
  # Chronicle makes embedding calls durable and replayable
  # (embedding.requested / embedding.responded, idempotency-keyed replay);
  # MemoryGateway decides memory semantics — what gets embedded, when,
  # subject scope, hybrid ranking, persistence on memory_item, fallback.
  #
  # The pack never instantiates a provider directly (no OpenAIEmbedder in
  # backend code) — it depends on this small interface, bound per runtime
  # graph so configuration never leaks across runtime instances. Chronicle
  # will own the durable implementation; RecordedEmbeddingService below is
  # the pack's reference until then.

  # Why vectors are being computed — chronicle's EmbeddingPurpose analog.
  enum EmbeddingPurpose
    MemoryWrite
    MemoryRetrieval
  end

  # A recorded embedding operation: turns texts into vectors, durably.
  # `idempotency_key` lets a prior result replay without re-contacting a
  # provider; `metadata` carries domain context (memory_item/candidate id,
  # subject_ref, correlation/causation/frame ids) for the durable log.
  abstract class EmbeddingService
    # Embedding-space identity — never cosine-compare vectors from different
    # model/version spaces.
    getter model : String = ""
    getter dimensions : Int32 = 0
    getter version : String = ""

    abstract def embed_texts(texts : Array(String), purpose : EmbeddingPurpose, idempotency_key : String, metadata : Hash(String, JSON::Any)) : Array(Array(Float64))
  end

  # Reference recorded implementation over any Embedder. Emits durable
  # embedding.requested / embedding.responded events on the bound graph and
  # replays a prior result from the log by idempotency key — zero provider
  # contact on replay, surviving service recreation. Delegate of choice: a
  # Crig::Embeddings::EmbeddingModel wrapped by a host-provided Embedder.
  class RecordedEmbeddingService < EmbeddingService
    getter graph : Chronicle::GraphProjection
    getter embedder : Embedder
    getter model : String
    getter dimensions : Int32
    getter version : String

    def initialize(@graph : Chronicle::GraphProjection, @embedder : Embedder, @version : String = "1")
      @model = @embedder.default_model
      @dimensions = 0
    end

    def embed_texts(texts : Array(String), purpose : EmbeddingPurpose, idempotency_key : String, metadata : Hash(String, JSON::Any)) : Array(Array(Float64))
      unless idempotency_key.empty?
        if replayed = _replay_from_log(idempotency_key)
          return replayed
        end
      end

      _emit_requested(texts, purpose, idempotency_key, metadata)
      vectors = @embedder.embed(texts, model: @model)
      @dimensions = vectors.first?.try(&.size) || @dimensions
      _emit_responded(purpose, idempotency_key, vectors)
      vectors
    end

    # Replay a prior embedding.responded for this idempotency key from the
    # durable log (keyless replay works entirely from the log).
    private def _replay_from_log(idempotency_key : String) : Array(Array(Float64))?
      graph.events.reverse_each do |event|
        next unless event.type == "embedding.responded"

        payload = JSON.parse(event.payload).as_h
        next unless payload["idempotency_key"]?.try(&.as_s?) == idempotency_key

        return (payload["vectors"]?.try(&.as_a) || [] of JSON::Any).map { |vec| vec.as_a.map(&.as_f) }
      end
      nil
    end

    private def _emit_requested(texts : Array(String), purpose : EmbeddingPurpose, idempotency_key : String, metadata : Hash(String, JSON::Any)) : Nil
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16,
        sequence: graph.events.size.to_u64 + 1,
        id: "embed_req_#{graph.events.size + 1}",
        type: "embedding.requested",
        actor: "memory_gateway",
        caused_by: nil,
        payload: {
          "purpose"         => JSON::Any.new(purpose.to_s),
          "idempotency_key" => JSON::Any.new(idempotency_key),
          "model"           => JSON::Any.new(@model),
          "version"         => JSON::Any.new(@version),
          "text_count"      => JSON::Any.new(texts.size),
          "metadata"        => JSON::Any.new(metadata),
        }.to_json,
      ))
    end

    private def _emit_responded(purpose : EmbeddingPurpose, idempotency_key : String, vectors : Array(Array(Float64))) : Nil
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16,
        sequence: graph.events.size.to_u64 + 1,
        id: "embed_resp_#{graph.events.size + 1}",
        type: "embedding.responded",
        actor: "memory_gateway",
        caused_by: nil,
        payload: {
          "purpose"         => JSON::Any.new(purpose.to_s),
          "idempotency_key" => JSON::Any.new(idempotency_key),
          "model"           => JSON::Any.new(@model),
          "version"         => JSON::Any.new(@version),
          "dimensions"      => JSON::Any.new(vectors.first?.try(&.size) || 0),
          "vectors"         => JSON::Any.new(vectors.map { |vec| JSON.parse(vec.to_json) }),
        }.to_json,
      ))
    end
  end
end

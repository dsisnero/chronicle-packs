require "json"

module Chronicle::Packs::MemoryGateway
  # Graph-backed memory store. Ported from upstream
  # packs/memory_gateway/backend.py: the memory_item graph objects ARE the
  # store; retrieval scans them with the pure lexical_score (embedding/SQLite
  # backends are deferred). lexical_score matches upstream exactly.

  # Anything that turns text into vectors — the one method the backend
  # needs. Upstream's Embedder protocol; implementations live in
  # embedders.cr or in the application.
  abstract class Embedder
    getter default_model : String = ""

    abstract def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
  end

  module Backend
    STOPWORDS = %w(the a an and or but if then else when while of to in on at for from by with without about into over after before under between during through as is are was were be been being do does did have has had can could should would may might must not no yes this that these those i you he she it we they them him her its their our your my his its me us him her them what which who whom whose why how where when all any both each few more most other some such only own same so than too very just also).to_set

    class_property _embedder : Embedder? = nil
    class_property _embedder_factory : Proc(Embedder?)? = nil
    # Per-runtime (per graph) recorded embedding services. Bound explicitly
    # so configuration never leaks across runtime instances; first-party
    # packs prefer this over the process-global embedder. _safe_embed
    # degrades a failing recorded call to lexical, never to an unrecorded
    # direct call.
    class_property embedding_services : Hash(Chronicle::GraphProjection, EmbeddingService) = {} of Chronicle::GraphProjection => EmbeddingService

    def self.set_embedding_service(graph : Chronicle::GraphProjection, service : EmbeddingService) : Nil
      self.embedding_services[graph] = service
    end

    def self.embedding_service(graph : Chronicle::GraphProjection) : EmbeddingService?
      self.embedding_services[graph]?
    end

    def self.clear_embedding_services : Nil
      self.embedding_services.clear
    end

    # ameba:disable Naming/AccessorMethodName -- faithful port of upstream backend.set_embedder
    def self.set_embedder(embedder : Embedder?) : Nil
      self._embedder = embedder
    end

    # ameba:disable Naming/AccessorMethodName -- faithful port of upstream backend.get_embedder
    def self.get_embedder : Embedder?
      self._embedder
    end

    def self.clear_embedder : Nil
      self._embedder = nil
    end

    # ameba:disable Naming/AccessorMethodName -- faithful port of upstream backend.set_embedder_factory
    def self.set_embedder_factory(factory : Proc(Embedder?)?) : Nil
      self._embedder_factory = factory
    end

    # Best-effort, never-raises switch to embedding-based recall. If an
    # embedder is already set, it wins; otherwise the registered factory is
    # tried. With no factory / no key / any error we stay lexical.
    def self.auto_configure_embedder : Embedder?
      if emb = self._embedder
        return emb
      end
      factory = self._embedder_factory
      return nil if factory.nil?

      begin
        emb = factory.call
      rescue
        return nil
      end
      if emb
        set_embedder(emb)
      end
      emb
    end

    # Call an embedder in whichever shape it implements (runtime
    # EmbeddingProvider protocol preferred, legacy embed(texts) fallback).
    def self._invoke_embedder(emb : Embedder, texts : Array(String)) : Array(Array(Float64))
      emb.embed(texts, model: emb.default_model)
    end

    def self._recorded_embed_fn(graph : Chronicle::GraphProjection) : EmbeddingService?
      embedding_service(graph)
    end

    # Bind *service* to *graph* for the block, restoring the prior binding
    # after. Yields True when a recorded path was bound.
    def self.runtime_recorded_embedding(graph : Chronicle::GraphProjection, service : EmbeddingService?, &) : Bool
      previous = embedding_service(graph)
      set_embedding_service(graph, service) if service
      begin
        yield !service.nil?
      ensure
        if previous
          set_embedding_service(graph, previous)
        else
          embedding_services.delete(graph)
        end
      end
    end

    # Embed texts, swallowing any failure -> nil (lexical fallback).
    # Prefers the graph's recorded EmbeddingService; otherwise the
    # process-global embedder. Returns vectors plus their embedding-space
    # identity so callers never blend incompatible spaces.
    def self._safe_embed(graph : Chronicle::GraphProjection, texts : Array(String), purpose : EmbeddingPurpose = EmbeddingPurpose::MemoryRetrieval, idempotency_key : String = "", metadata : Hash(String, JSON::Any) = {} of String => JSON::Any) : EmbeddingOutcome?
      if service = embedding_service(graph)
        begin
          vectors = service.embed_texts(texts, purpose, idempotency_key, metadata)
        rescue
          return nil
        end
        return nil if vectors.empty? || vectors.size != texts.size

        return EmbeddingOutcome.new(vectors, service.model, service.dimensions, service.version)
      end
      emb = get_embedder
      return nil if emb.nil?

      begin
        vectors = _invoke_embedder(emb, texts)
      rescue
        return nil
      end
      return nil if vectors.empty? || vectors.size != texts.size

      EmbeddingOutcome.new(vectors, emb.default_model, vectors.first.size, "legacy")
    end

    # Cosine similarity clamped to [0,1] so scores compose with the lexical
    # [0,1] range and the shared min_score threshold.
    def self._cosine(a : Array(Float64), b : Array(Float64)) : Float64
      return 0.0 if a.empty? || b.empty? || a.size != b.size

      dot = 0.0
      a.zip(b) { |x, y| dot += x * y }
      na = Math.sqrt(a.sum { |x| x * x })
      nb = Math.sqrt(b.sum { |y| y * y })
      return 0.0 if na == 0.0 || nb == 0.0

      Math.max(0.0, Math.min(1.0, dot / (na * nb)))
    end

    # Vectors plus their embedding-space identity. Two vectors are only
    # comparable when model AND version agree; otherwise lexical-fallback.
    record EmbeddingOutcome, vectors : Array(Array(Float64)), model : String = "", dimensions : Int32 = 0, version : String = ""

    def self._word_set(text : String) : Set(String)
      words = text.downcase.scan(/[a-z]+/).map(&.[0])
      words.reject { |word| STOPWORDS.includes?(word) || word.size <= 2 }.to_set
    end

    # Max of Jaccard overlap and query-term coverage, in [0, 1].
    def self.lexical_score(query : String, text : String) : Float64
      qwords = _word_set(query)
      twords = _word_set(text)
      return 0.0 if qwords.empty? || twords.empty?

      overlap = (qwords & twords).size
      coverage = overlap.to_f64 / qwords.size
      jaccard = overlap.to_f64 / (qwords | twords).size
      Math.max(jaccard, coverage)
    end

    # Normalize memory text for dedup.
    def self._normalize_text(text : String) : String
      text.strip.downcase.gsub(/\s+/, " ").rstrip(".!?,;: ")
    end

    # Retrieve MemoryItems ranked by similarity to *query*. The item's score
    # is the MAX of the lexical signal and (when the query embeds AND the
    # item has a stored vector in the SAME model/version space) cosine —
    # never worse than either pure mode. Both signals live on the same [0,1]
    # scale; a missing/failing embedder or a space mismatch simply drops the
    # cosine signal, so embedded and non-embedded items coexist safely.
    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream retrieval filters
    def self.retrieve_by_query(graph : Chronicle::GraphProjection, query : String, top_k : Int32 = 10, min_score : Float64 = 0.2, category : String? = nil, subject_ref : String? = nil, subject_scoped : Bool = false, include_global : Bool = true, exclude_frame_id : String? = nil) : Array(Hash(String, JSON::Any))
      query_outcome = _safe_embed(graph, [query], EmbeddingPurpose::MemoryRetrieval)
      query_vec = query_outcome.try(&.vectors[0])
      results = [] of Hash(String, JSON::Any)
      graph.objects(type: "memory_item").each do |obj|
        data = JSON.parse(obj.data).as_h
        text = data["text"]?.try(&.as_s?) || ""
        next if category && data["category"]?.try(&.as_s?) != category
        if subject_scoped
          item_subject = data["subject_ref"]?.try(&.as_s?)
          next if item_subject != subject_ref && !(item_subject.nil? && include_global)
        end
        if exclude_frame_id
          metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
          next if metadata["frame_id"]?.try(&.as_s?) == exclude_frame_id
        end
        raw = lexical_score(query, text)
        if query_vec && query_outcome && (embedding = data["embedding"]?.try(&.as_a?.try(&.map(&.as_f))))
          same_space = (data["embedding_model"]?.try(&.as_s?) || "") == query_outcome.model &&
                       (data["embedding_version"]?.try(&.as_s?) || "") == query_outcome.version
          raw = Math.max(raw, _cosine(query_vec, embedding)) if same_space
        end
        score = raw * (data["reliability_multiplier"]?.try(&.as_f?) || 0.0)
        next if score < min_score

        results << {
          "item_id"                => JSON::Any.new(obj.id),
          "text"                   => JSON::Any.new(text),
          "score"                  => JSON::Any.new(score),
          "raw_score"              => JSON::Any.new(raw),
          "category"               => data["category"]? || JSON::Any.new(nil),
          "confidence"             => data["confidence"]? || JSON::Any.new(0.7),
          "reliability_verdict"    => data["reliability_verdict"]? || JSON::Any.new("weak"),
          "reliability_multiplier" => data["reliability_multiplier"]? || JSON::Any.new(1.0),
        }
      end
      results.sort_by! { |row| -row["score"].as_f }
      results[0, top_k]
    end

    # Find an item with this exact (normalized) text in the same subject
    # scope. An existing global/untagged row is a dedup wildcard for a named
    # caller so memory_writer can upgrade that survivor to the source author
    # instead of leaving author-owned memory globally recallable.
    def self.find_by_text(graph : Chronicle::GraphProjection, text : String, subject_ref : String?) : String?
      needle = _normalize_text(text)
      graph.objects(type: "memory_item").find do |obj|
        data = JSON.parse(obj.data).as_h
        _normalize_text(data["text"]?.try(&.as_s?) || "") == needle &&
          begin
            item_subject = data["subject_ref"]?.try(&.as_s?)
            item_subject == subject_ref || (item_subject.nil? && !subject_ref.nil?)
          end
      end.try(&.id)
    end

    def self.get_subject(graph : Chronicle::GraphProjection, item_id : String) : String?
      obj = graph.get_object(item_id)
      return nil if obj.nil?

      JSON.parse(obj.data)["subject_ref"]?.try(&.as_s?)
    end

    def self.set_subject(graph : Chronicle::GraphProjection, item_id : String, subject_ref : String?) : Nil
      obj = graph.get_object(item_id)
      return if obj.nil?

      item = MemoryItem.from_json(obj.data)
      graph.patch_object(item_id, item.copy_with(subject_ref: subject_ref).to_json)
    end

    def self.update_retrieval(graph : Chronicle::GraphProjection, item_id : String) : Nil
      obj = graph.get_object(item_id)
      return if obj.nil?

      item = MemoryItem.from_json(obj.data)
      graph.patch_object(item_id, item.copy_with(retrieval_count: item.retrieval_count + 1, last_retrieved_at: Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")).to_json)
    end

    def self.set_reliability(graph : Chronicle::GraphProjection, item_id : String, verdict : String, multiplier : Float64) : Nil
      obj = graph.get_object(item_id)
      return if obj.nil?

      item = MemoryItem.from_json(obj.data)
      parsed_verdict = ReliabilityVerdict.parse?(verdict) || ReliabilityVerdict::Weak
      graph.patch_object(item_id, item.copy_with(reliability_verdict: parsed_verdict, reliability_multiplier: multiplier).to_json)
    end

    # Evict least-recently-used items until at most max_items remain.
    def self.enforce_limit(graph : Chronicle::GraphProjection, max_items : Int32) : Nil
      items = graph.objects(type: "memory_item")
      return if items.size <= max_items

      items.sort_by! do |obj|
        data = JSON.parse(obj.data).as_h
        data["last_retrieved_at"]?.try(&.as_s?) || data["created_at"]?.try(&.as_s?) || ""
      end
      items[0, items.size - max_items].each { |obj| graph.remove_object(obj.id) }
    end
  end
end

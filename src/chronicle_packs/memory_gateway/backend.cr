require "json"

module Chronicle::Packs::MemoryGateway
  # Graph-backed memory store. Ported from upstream
  # packs/memory_gateway/backend.py: the memory_item graph objects ARE the
  # store; retrieval scans them with the pure lexical_score (embedding/SQLite
  # backends are deferred). lexical_score matches upstream exactly.

  module Backend
    STOPWORDS = %w(the a an and or but if then else when while of to in on at for from by with without about into over after before under between during through as is are was were be been being do does did have has had can could should would may might must not no yes this that these those i you he she it we they them him her its their our your my his its me us him her them what which who whom whose why how where when all any both each few more most other some such only own same so than too very just also).to_set

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

    # Retrieve MemoryItems ranked by similarity to *query* (lexical signal).
    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream retrieval filters
    def self.retrieve_by_query(graph : Chronicle::GraphProjection, query : String, top_k : Int32 = 10, min_score : Float64 = 0.2, category : String? = nil, subject_ref : String? = nil, subject_scoped : Bool = false, include_global : Bool = true, exclude_frame_id : String? = nil) : Array(Hash(String, JSON::Any))
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
        next if raw < min_score

        results << {
          "item_id"                => JSON::Any.new(obj.id),
          "text"                   => JSON::Any.new(text),
          "score"                  => JSON::Any.new(raw),
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

    # Find an item with this exact (normalized) text in the same subject scope.
    def self.find_by_text(graph : Chronicle::GraphProjection, text : String, subject_ref : String?) : String?
      needle = _normalize_text(text)
      graph.objects(type: "memory_item").find do |obj|
        data = JSON.parse(obj.data).as_h
        _normalize_text(data["text"]?.try(&.as_s?) || "") == needle &&
          data["subject_ref"]?.try(&.as_s?) == subject_ref
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

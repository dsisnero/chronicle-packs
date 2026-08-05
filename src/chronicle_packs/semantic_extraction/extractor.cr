require "json"
require "digest"

module Chronicle::Packs::SemanticExtraction
  # Deterministic annotation extractor v1 — the zero-key floor. Ported from
  # upstream packs/semantic_extraction/extractor.py. Pure string/regex
  # operations, byte-deterministic, no wall-clock, no network, no keys.

  # One proposed annotation before graph materialization.
  record AnnotationDraft,
    facet : String,
    body : Hash(String, JSON::Any),
    start : Int32,
    end : Int32,
    exact : String,
    confidence : Float64,
    modality : String = "stated",
    polarity : String = "positive",
    event_time : String? = nil,
    metadata : Hash(String, JSON::Any) = {} of String => JSON::Any do
  end

  def self.config_hash_for(config : Hash(String, JSON::Any)) : String
    canonical = JSON.build do |json|
      json.object do
        config.to_a.sort_by(&.[0]).each { |key, value| json.field key, value }
      end
    end
    Digest::SHA256.hexdigest(canonical)
  end

  module Extractors
    EMAIL_RE               = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/
    URL_RE                 = /https?:\/\/[^\s)\]}>"',]+/
    HANDLE_RE              = /(?<![\w@.])@[A-Za-z0-9_]{2,32}\b/
    PROPER_MULTI_RE        = /\b[A-Z][A-Za-z0-9&'’-]+(?:\s+[A-Z][A-Za-z0-9&'’-]+)+\b/
    PROPER_SINGLE_RE       = /\b[A-Z][a-z0-9'’-]{2,}\b/
    SENTENCE_SPLIT_RE      = /(?<=[.!?])\s+|\n+/
    PREFERENCE_CUE_RE      = /\b(prefer(?:s|red)?|like(?:s)?|love(?:s)?|enjoy(?:s)?|hate(?:s)?|dislike(?:s)?|favor(?:s|ite)?|favourite|always\s+use(?:s)?|never\s+use(?:s)?|usually|rather\s+than|working\s+style)\b/i
    NEGATIVE_CUE_RE        = /\b(hate(?:s)?|dislike(?:s)?|never|not|doesn'?t|don'?t|isn'?t|aren'?t|won'?t|avoid(?:s)?)\b/i
    UNCERTAIN_CUE_RE       = /\b(maybe|might|possibly|perhaps|probably|seems?|appear(?:s)?)\b/i
    INTERROGATIVE_START_RE = /^(who|what|when|where|why|how|is|are|do|does|did|can|could|would|should|will)\b/i
    MONTHS                 = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    MONTH_INDEX            = MONTHS.each_with_index.to_h { |name, index| {name, index + 1} }
    MONTH_ALT              = MONTHS.join("|")
    ISO_DATE_RE            = /\b(\d{4})-(\d{2})-(\d{2})\b/
    MDY_RE                 = Regex.new("\\b(#{MONTH_ALT})\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b")
    DMY_RE                 = Regex.new("\\b(\\d{1,2})\\s+(#{MONTH_ALT})\\s+(\\d{4})\\b")
    MY_RE                  = Regex.new("\\b(#{MONTH_ALT})\\s+(\\d{4})\\b")
    TOKEN_RE               = /[A-Za-z][A-Za-z0-9_-]{3,}/
    BULLET_RE              = /^[-*•>\d.)\s]+/

    STOPWORDS = %w(a about above after again all also am an and any are as at be because been before being below between both but by could did do does doing down during each few for from further had has have having he her here hers him his how i if in into is it its itself just like me more most my myself no nor not now of off on once only or other our ours out over own same she should so some such than that the their theirs them then there these they this those through to too under until up very was we were what when where which while who whom why will with you your yours everything anything something things using used use know knows tell told).to_set

    PROPER_STOP = Set(String).new(["The", "This", "That", "There", "These", "Those", "When", "Where", "What", "Who", "Why", "How", "And", "But", "Also", "Then", "Here", "Yes", "No", "Not", "All", "Any", "Some", "Please", "Thanks"])

    # Deterministic sentence spans: (start, end, text), offsets exact.
    def self._sentences(content : String) : Array({Int32, Int32, String})
      spans = [] of {Int32, Int32, String}
      cursor = 0
      content.scan(SENTENCE_SPLIT_RE).each do |match|
        chunk = content[cursor...match.begin]
        if !chunk.strip.empty?
          spans << {cursor, match.begin, chunk}
        end
        cursor = match.end
      end
      tail = content[cursor..]
      if !tail.strip.empty?
        spans << {cursor, content.size, tail}
      end
      spans.compact_map do |start, stop, text|
        left = text.size - text.lstrip.size
        right = text.size - text.rstrip.size
        {start + left, stop - right, text.strip}
      end
    end

    def self._strip_bullet(text : String) : String
      text.gsub(BULLET_RE, "")
    end

    # The deterministic v1 extractor implementing the zero-key floor.
    class DeterministicExtractorV1
      property extractor_id : String = "semantic.deterministic"
      property extractor_version : String = "0.1.0"

      @max_content_chars : Int32
      @max_per_facet : Int32
      @min_assertion_chars : Int32
      @topic_tag_count : Int32

      def initialize(max_content_chars : Int32 = 32_000, max_annotations_per_facet : Int32 = 50, min_assertion_chars : Int32 = 15, topic_tag_count : Int32 = 5)
        @max_content_chars = max_content_chars
        @max_per_facet = max_annotations_per_facet
        @min_assertion_chars = min_assertion_chars
        @topic_tag_count = topic_tag_count
      end

      def implemented_facets : Array(String)
        Facets::V1_IMPLEMENTED_FACETS
      end

      def config : Hash(String, JSON::Any)
        {
          "max_content_chars"         => JSON::Any.new(@max_content_chars),
          "max_annotations_per_facet" => JSON::Any.new(@max_per_facet),
          "min_assertion_chars"       => JSON::Any.new(@min_assertion_chars),
          "topic_tag_count"           => JSON::Any.new(@topic_tag_count),
        }
      end

      def extract(content : String, metadata : Hash(String, JSON::Any), facets : Array(String)) : Array(AnnotationDraft)
        text = content[0, @max_content_chars]
        drafts = [] of AnnotationDraft
        facets.each do |facet|
          found = _extract_facet(facet, text)
          drafts.concat(found[0, @max_per_facet])
        end
        drafts
      end

      private def _extract_facet(facet : String, text : String) : Array(AnnotationDraft)
        case facet
        when "entity_mention"        then _extract_entity_mention(text)
        when "assertion"             then _extract_assertion(text)
        when "question"              then _extract_question(text)
        when "preference_expression" then _extract_preference_expression(text)
        when "temporal_expression"   then _extract_temporal_expression(text)
        when "topic_tag"             then _extract_topic_tag(text)
        else
          [] of AnnotationDraft
        end
      end

      private def _extract_entity_mention(text : String) : Array(AnnotationDraft)
        drafts = [] of AnnotationDraft
        claimed = [] of {Int32, Int32}

        add = ->(match_start : Int32, match_end : Int32, kind : String, exact : String, normalized : String, confidence : Float64) {
          claimed.each do |start, stop|
            return if match_start < stop && start < match_end
          end
          claimed << {match_start, match_end}
          drafts << AnnotationDraft.new("entity_mention", {"text" => JSON::Any.new(exact), "kind" => JSON::Any.new(kind), "normalized" => JSON::Any.new(normalized)}, match_start, match_end, exact, confidence)
        }

        text.scan(Extractors::EMAIL_RE).each { |match| add.call(match.begin, match.end, "email", match[0], match[0].downcase, 0.95) }
        text.scan(Extractors::URL_RE).each do |match|
          exact = match[0].rstrip(".,;:!?")
          add.call(match.begin, match.begin + exact.size, "url", exact, exact.rstrip("/").downcase, 0.95)
        end
        text.scan(Extractors::HANDLE_RE).each { |match| add.call(match.begin, match.end, "handle", match[0], match[0].downcase, 0.9) }
        text.scan(Extractors::PROPER_MULTI_RE).each do |match|
          exact = match[0]
          head = exact.split[0]
          next if Extractors::PROPER_STOP.includes?(head)

          add.call(match.begin, match.end, "proper_noun", exact, exact, 0.6)
        end
        sentence_starts = Extractors._sentences(text).map { |start, _stop, _t| start }.to_set
        text.scan(Extractors::PROPER_SINGLE_RE).each do |match|
          next if sentence_starts.includes?(match.begin)

          exact = match[0]
          next if Extractors::PROPER_STOP.includes?(exact) || Extractors::STOPWORDS.includes?(exact.downcase)
          next if Extractors::MONTH_INDEX.has_key?(exact)

          add.call(match.begin, match.end, "proper_noun", exact, exact, 0.55)
        end
        drafts.sort_by! { |draft| {draft.start, draft.end} }
        drafts
      end

      private def _extract_assertion(text : String) : Array(AnnotationDraft)
        drafts = [] of AnnotationDraft
        Extractors._sentences(text).each do |start, _stop, sentence|
          stripped = Extractors._strip_bullet(sentence)
          next if stripped.size < @min_assertion_chars
          next if stripped.ends_with?("?") || stripped.ends_with?(":")
          next if Extractors::INTERROGATIVE_START_RE.matches?(stripped)
          next unless stripped.includes?(" ")

          modality = Extractors::UNCERTAIN_CUE_RE.matches?(stripped) ? "uncertain" : "stated"
          polarity = Extractors::NEGATIVE_CUE_RE.matches?(stripped) ? "negative" : "positive"
          offset = start + (sentence.size - sentence.lstrip.size)
          offset += sentence.strip.size - stripped.size
          drafts << AnnotationDraft.new("assertion", {"text" => JSON::Any.new(stripped)}, offset, offset + stripped.size, stripped, 0.7, modality: modality, polarity: polarity)
        end
        drafts
      end

      private def _extract_question(text : String) : Array(AnnotationDraft)
        drafts = [] of AnnotationDraft
        Extractors._sentences(text).each do |_start, stop, sentence|
          stripped = Extractors._strip_bullet(sentence)
          next unless stripped.ends_with?("?")
          next if stripped.size < 4

          offset = stop - stripped.size
          drafts << AnnotationDraft.new("question", {"text" => JSON::Any.new(stripped)}, offset, stop, stripped, 0.8)
        end
        drafts
      end

      private def _extract_preference_expression(text : String) : Array(AnnotationDraft)
        drafts = [] of AnnotationDraft
        Extractors._sentences(text).each do |_start, stop, sentence|
          stripped = Extractors._strip_bullet(sentence)
          match = Extractors::PREFERENCE_CUE_RE.match(stripped)
          next if match.nil? || stripped.ends_with?("?")

          polarity = Extractors::NEGATIVE_CUE_RE.matches?(stripped) ? "negative" : "positive"
          offset = stop - stripped.size
          drafts << AnnotationDraft.new("preference_expression", {"text" => JSON::Any.new(stripped), "cue" => JSON::Any.new(match[0].downcase)}, offset, stop, stripped, 0.75, polarity: polarity)
        end
        drafts
      end

      private def _extract_temporal_expression(text : String) : Array(AnnotationDraft)
        drafts = [] of AnnotationDraft
        claimed = [] of {Int32, Int32}

        add = ->(match_start : Int32, match_end : Int32, exact : String, normalized : String, precision : String) {
          claimed.each do |start, stop|
            return if match_start < stop && start < match_end
          end
          claimed << {match_start, match_end}
          drafts << AnnotationDraft.new("temporal_expression", {"text" => JSON::Any.new(exact), "normalized" => JSON::Any.new(normalized), "precision" => JSON::Any.new(precision)}, match_start, match_end, exact, 0.9, event_time: normalized)
        }

        text.scan(Extractors::ISO_DATE_RE).each do |match|
          year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
          next unless (1..12).includes?(month) && (1..31).includes?(day)

          add.call(match.begin, match.end, match[0], sprintf("%04d-%02d-%02d", year, month, day), "day")
        end
        text.scan(Extractors::MDY_RE).each do |match|
          month = Extractors::MONTH_INDEX[match[1]]
          day, year = match[2].to_i, match[3].to_i
          next unless (1..31).includes?(day)

          add.call(match.begin, match.end, match[0], sprintf("%04d-%02d-%02d", year, month, day), "day")
        end
        text.scan(Extractors::DMY_RE).each do |match|
          day = match[1].to_i
          month = Extractors::MONTH_INDEX[match[2]]
          year = match[3].to_i
          next unless (1..31).includes?(day)

          add.call(match.begin, match.end, match[0], sprintf("%04d-%02d-%02d", year, month, day), "day")
        end
        text.scan(Extractors::MY_RE).each do |match|
          month = Extractors::MONTH_INDEX[match[1]]
          year = match[2].to_i
          add.call(match.begin, match.end, match[0], sprintf("%04d-%02d", year, month), "month")
        end
        drafts.sort_by! { |draft| {draft.start, draft.end} }
        drafts
      end

      private def _extract_topic_tag(text : String) : Array(AnnotationDraft)
        counts = {} of String => Int32
        first_span = {} of String => {Int32, Int32}
        text.scan(Extractors::TOKEN_RE).each do |match|
          token = match[0].downcase
          next if Extractors::STOPWORDS.includes?(token)

          counts[token] = (counts[token]? || 0) + 1
          first_span[token] = {match.begin, match.end} unless first_span.has_key?(token)
        end
        ranked = counts.to_a.sort_by! { |token, count| {-count, token} }
        drafts = [] of AnnotationDraft
        ranked[0, @topic_tag_count].each do |token, count|
          next if count < 2

          start, stop = first_span[token]
          drafts << AnnotationDraft.new("topic_tag", {"tag" => JSON::Any.new(token), "occurrences" => JSON::Any.new(count)}, start, stop, text[start...stop], 0.5)
        end
        drafts
      end
    end

    # Registry keyed by immutable (extractor_id, extractor_version).
    module ExtractorRegistry
      REGISTRY = {} of {String, String} => DeterministicExtractorV1
    end

    def self.register_annotation_extractor(extractor : DeterministicExtractorV1, replace : Bool = false) : Nil
      key = {extractor.extractor_id, extractor.extractor_version}
      existing = ExtractorRegistry::REGISTRY[key]?
      raise "extractor already registered: #{key}" if existing && existing != extractor && !replace

      ExtractorRegistry::REGISTRY[key] = extractor
    end

    def self.get_annotation_extractor(extractor_id : String, extractor_version : String) : DeterministicExtractorV1
      ExtractorRegistry::REGISTRY[{extractor_id, extractor_version}]? || raise KeyError.new("unknown annotation extractor: {#{extractor_id}, #{extractor_version}}")
    end
  end

  # Seed the registry with the deterministic floor (upstream registers at import).
  Extractors.register_annotation_extractor(Extractors::DeterministicExtractorV1.new)
end

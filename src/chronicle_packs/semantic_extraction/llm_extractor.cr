require "json"
require "digest"

module Chronicle::Packs::SemanticExtraction
  # LLM-backed annotation extractor (D025 stage two) at the shared registry
  # seam. The LLM proposes candidate drafts; the extractor verifies every
  # byte-exact anchor, shapes facet bodies, and caps per facet — an LLM may
  # not mint an annotation whose anchor does not exist. Provider calls ride
  # the recorded completion boundary.

  module Extractors
    SYSTEM_PROMPT = <<-PROMPT.strip
      You are an annotation extractor for a provenance-first knowledge graph. Extract annotations from the user-supplied CONTENT for exactly the requested FACETS, and reply with a JSON array (no prose, no code fences). Each element:
      {"facet": "<facet name>", "exact": "<verbatim substring of CONTENT — copied byte-for-byte>", "occurrence": <1-based index if the substring appears more than once>, "body": {<facet body>}, "modality": "stated" | "uncertain" | "hypothetical", "polarity": "positive" | "negative", "confidence": <0.0-1.0>, "event_time": "<ISO date if the annotation is about a dated event, else null>"}
      Facet bodies:
      - entity_mention: {"text": exact, "kind": "person" | "organization" | "place" | "product" | "handle" | "email" | "url" | "other", "normalized": "<canonical form>"}
      - assertion: {"text": exact} — judge modality and polarity carefully.
      - preference_expression: {"text": exact, "cue": "<the preference cue word>"}
      - relation_mention: {"text": exact, "subject": "...", "predicate": "...", "object": "..."}
      - event_mention: {"text": exact, "name": "<short event name>", "participants": ["..."], "when": "<ISO date or null>"}
      Rules: "exact" MUST be a verbatim contiguous substring of CONTENT — never paraphrase, never fix typos, never merge spans. Only emit facets that were requested. Prefer precision over recall.
      PROMPT

    class LLMExtractorV1 < AnnotationExtractor
      property extractor_id : String = "semantic.llm"
      property extractor_version : String = "0.1.0"

      PROMPT_VERSION = "1"

      getter provider : RecordedCompletion
      getter model : String
      getter max_content_chars : Int32
      getter max_per_facet : Int32
      getter max_output_tokens : Int32
      getter timeout_seconds : Float64

      def initialize(provider : RecordedCompletion, model : String, max_content_chars : Int32 = 32_000, max_annotations_per_facet : Int32 = 50, max_output_tokens : Int32 = 4_096, timeout_seconds : Float64 = 60.0)
        raise Chronicle::Packs::PackError.new("semantic.llm needs an explicit model — it is part of the extractor's cache identity (config_hash) and must be stable across record and replay") if model.empty?

        @provider = provider
        @model = model
        @max_content_chars = max_content_chars
        @max_per_facet = max_annotations_per_facet
        @max_output_tokens = max_output_tokens
        @timeout_seconds = timeout_seconds
      end

      def implemented_facets : Array(String)
        Facets::LLM_IMPLEMENTED_FACETS
      end

      def config : Hash(String, JSON::Any)
        {
          "model"                     => JSON::Any.new(@model),
          "prompt_version"            => JSON::Any.new(PROMPT_VERSION),
          "max_content_chars"         => JSON::Any.new(@max_content_chars),
          "max_annotations_per_facet" => JSON::Any.new(@max_per_facet),
          "max_output_tokens"         => JSON::Any.new(@max_output_tokens),
        }
      end

      def extract(content : String, metadata : Hash(String, JSON::Any), facets : Array(String)) : Array(AnnotationDraft)
        requested = (facets.to_set & Facets::LLM_IMPLEMENTED_FACETS.to_set).to_a.sort
        return [] of AnnotationDraft if requested.empty?

        text = content[0, @max_content_chars]
        response = _complete(text, requested)
        items = _parse_items(response)
        drafts = _verify_and_draft(text, requested, items)
        drafts.sort_by! { |draft| {draft.facet, draft.start, draft.end} }

        capped = [] of AnnotationDraft
        per_facet = {} of String => Int32
        drafts.each do |draft|
          count = per_facet[draft.facet]? || 0
          next if count >= @max_per_facet

          per_facet[draft.facet] = count + 1
          capped << draft
        end
        capped
      end

      private def _complete(content : String, facets : Array(String)) : String
        user = "FACETS: #{facets.to_json}\nCONTENT:\n#{content}"
        input = "SYSTEM:\n#{SYSTEM_PROMPT}\n\nUSER:\n#{user}"
        idempotency_key = Digest::SHA256.hexdigest("#{@model}\u{1f}#{SYSTEM_PROMPT}\u{1f}#{user}")
        @provider.structured(input, idempotency_key, {"model" => JSON::Any.new(@model), "facets" => JSON::Any.new(facets.map { |facet| JSON::Any.new(facet) })})
      end

      private def _parse_items(raw_text : String) : Array(Hash(String, JSON::Any))
        text = _strip_code_fence(raw_text)
        parsed = begin
          JSON.parse(text)
        rescue
          return [] of Hash(String, JSON::Any)
        end
        return [] of Hash(String, JSON::Any) unless parsed.raw.is_a?(Array)

        parsed.as_a.compact_map(&.as_h?)
      end

      # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream byte-exact verification
      private def _verify_and_draft(text : String, requested : Array(String), items : Array(Hash(String, JSON::Any))) : Array(AnnotationDraft)
        drafts = [] of AnnotationDraft
        items.each do |item|
          facet = item["facet"]?.try(&.as_s?)
          exact = item["exact"]?.try(&.as_s?)
          next if facet.nil? || !requested.includes?(facet) || exact.nil? || exact.empty?

          occurrence = item["occurrence"]?.try(&.as_i?)
          start = _locate(text, exact, occurrence)
          next if start.nil?

          body = _facet_body(facet, exact, item["body"]?)
          next if body.nil?

          modality = item["modality"]?.try(&.as_s?) || "stated"
          modality = "stated" unless modality.in?({"stated", "uncertain", "hypothetical"})
          polarity = item["polarity"]?.try(&.as_s?) || "positive"
          polarity = "positive" unless polarity.in?({"positive", "negative"})
          event_time = item["event_time"]?.try(&.as_s?)
          event_time = nil if event_time.nil? || event_time.empty?

          drafts << AnnotationDraft.new(
            facet, body, start, start + exact.size, exact,
            _clamp(item["confidence"]?, 0.6),
            modality: modality, polarity: polarity, event_time: event_time,
            metadata: {"proposed_by" => JSON::Any.new("llm")},
          )
        end
        drafts
      end

      # Shape and sanity-check one facet body; nil drops the item. Full
      # schema validation still happens in the engine (validate_body).
      # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream per-facet shaping
      private def _facet_body(facet : String, exact : String, raw_body : JSON::Any?) : Hash(String, JSON::Any)?
        body = raw_body.try(&.as_h) || {} of String => JSON::Any
        case facet
        when "entity_mention"
          kind = body["kind"]?.try(&.as_s?)
          kind = "other" unless kind.in?({"handle", "email", "url", "proper_noun", "person", "organization", "place", "product", "other"})
          normalized = body["normalized"]?.try(&.as_s?)
          normalized = exact if normalized.nil? || normalized.empty?
          {"text" => JSON::Any.new(exact), "kind" => JSON::Any.new(kind), "normalized" => JSON::Any.new(normalized)}
        when "assertion"
          {"text" => JSON::Any.new(exact)}
        when "preference_expression"
          cue = body["cue"]?.try(&.as_s?)
          return nil if cue.nil? || cue.empty?

          {"text" => JSON::Any.new(exact), "cue" => JSON::Any.new(cue.downcase)}
        when "relation_mention"
          subject = body["subject"]?.try(&.as_s?)
          predicate = body["predicate"]?.try(&.as_s?)
          object = body["object"]?.try(&.as_s?)
          return nil if subject.nil? || subject.empty? || predicate.nil? || predicate.empty? || object.nil? || object.empty?

          {"text" => JSON::Any.new(exact), "subject" => JSON::Any.new(subject), "predicate" => JSON::Any.new(predicate), "object" => JSON::Any.new(object)}
        when "event_mention"
          name = body["name"]?.try(&.as_s?)
          return nil if name.nil? || name.empty?

          participants = body["participants"]?.try(&.as_a) || [] of JSON::Any
          participants = participants.compact_map(&.as_s?).reject(&.empty?)
          when_value = body["when"]?.try(&.as_s?)
          when_value = nil if when_value.nil? || when_value.empty?
          {"text" => JSON::Any.new(exact), "name" => JSON::Any.new(name), "participants" => JSON::Any.new(participants.map { |participant| JSON::Any.new(participant) }), "when" => when_value ? JSON::Any.new(when_value) : JSON::Any.new(nil)}
        else
          nil
        end
      end

      private def _locate(text : String, exact : String, occurrence : Int32?) : Int32?
        if occurrence && occurrence >= 1
          start = -1
          occurrence.times do
            start = text.index(exact, start + 1)
            return nil if start.nil?
          end
          return start
        end
        start = text.index(exact)
        start.nil? ? nil : start
      end

      private def _clamp(value : JSON::Any?, default : Float64) : Float64
        raw = value.try(&.as_f?)
        return default if raw.nil?

        Math.max(0.0, Math.min(1.0, raw))
      end

      private def _strip_code_fence(raw : String) : String
        text = raw.strip
        match = text.match(/\A```(?:json)?\s*(.*?)\s*```\z/m)
        match ? match[1] : text
      end
    end
  end

  # Construct the LLM extractor from settings + a live provider proc.
  # Registration is explicit (replace: true) so a settings change rebuilds
  # the extractor under the same immutable (id, version) identity.
  def self.build_llm_extractor(settings : SemanticExtractionSettings, graph : Chronicle::GraphProjection, provider : Proc(String, String, String)? = nil) : Extractors::LLMExtractorV1
    if provider.nil? && settings.llm_record_dir.empty?
      raise Chronicle::Packs::PackError.new("semantic.llm needs a configured LLM provider or a llm_record_dir to replay from (zero-key mode uses the deterministic extractor only)")
    end
    model = settings.llm_model
    completion = RecordedCompletionService.new(graph, model, provider)
    extractor = Extractors::LLMExtractorV1.new(
      provider: completion, model: model,
      max_content_chars: settings.max_content_chars,
      max_annotations_per_facet: settings.max_annotations_per_facet,
      max_output_tokens: settings.llm_max_output_tokens,
      timeout_seconds: settings.llm_timeout_seconds,
    )
    Extractors.register_annotation_extractor(extractor, replace: true)
    extractor
  end
end

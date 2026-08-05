require "json"

module Chronicle::Packs::ActivityNormalizer
  # The legacy structure extractor as an annotation emitter (ADR 0026 step 2).
  # Ported from upstream packs/activity_normalizer/annotation_extractor.py.
  # activity.structure@0.2.0 registers at the shared extraction seam and
  # emits the exact same findings the legacy 0.1.0 candidate extractor did —
  # now as source-anchored annotations under namespaced extension facets.
  # Draft parity is load-bearing: (kind, text, ordinal) must match the
  # legacy extractor byte-for-byte.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module AnnotationExtractor
    FACET_BY_KIND = {
      "memory"     => "activity.memory",
      "preference" => "activity.preference",
      "task"       => "activity.task",
      "profile"    => "activity.profile",
      "skill"      => "activity.skill",
      "eval"       => "activity.eval",
    }
    KIND_BY_FACET    = FACET_BY_KIND.to_h { |kind, facet| {facet, kind} }
    STRUCTURE_FACETS = KIND_BY_FACET.keys.sort!

    CLEAN_RE = /\s+/

    def self._clean(value : String, limit : Int32) : String
      value.gsub(CLEAN_RE, " ").strip[0, limit]
    end

    # The 0.1.0 structure heuristics, emitted as annotations.
    class StructureAnnotationExtractor < Chronicle::Packs::SemanticExtraction::Extractors::AnnotationExtractor
      property extractor_id : String = "activity.structure"
      property extractor_version : String = "0.2.0"

      @max_candidates : Int32
      @max_candidate_chars : Int32
      @legacy : Chronicle::Packs::ActivityNormalizer::Extractors::StructureExtractor

      def initialize(max_candidates : Int32 = 32, max_candidate_chars : Int32 = 2000)
        @max_candidates = max_candidates
        @max_candidate_chars = max_candidate_chars
        @legacy = Chronicle::Packs::ActivityNormalizer::Extractors::StructureExtractor.new
      end

      def implemented_facets : Array(String)
        STRUCTURE_FACETS
      end

      def config : Hash(String, JSON::Any)
        {"max_candidates" => JSON::Any.new(@max_candidates), "max_candidate_chars" => JSON::Any.new(@max_candidate_chars)}
      end

      def extract(content : String, metadata : Hash(String, JSON::Any), facets : Array(String)) : Array(Chronicle::Packs::SemanticExtraction::AnnotationDraft)
        requested_kinds = facets.compact_map { |facet| KIND_BY_FACET[facet]? }.to_set
        return [] of Chronicle::Packs::SemanticExtraction::AnnotationDraft if requested_kinds.empty?

        # The exact legacy draft list decides (kind, text, ordinal) — ordinals
        # are positions in THIS list, before facet filtering, so they match the
        # legacy candidate identities regardless of which facets a profile asks.
        drafts = @legacy.extract(content, metadata, @max_candidates, @max_candidate_chars)
        spans = _line_spans(content, @max_candidate_chars)
        out = [] of Chronicle::Packs::SemanticExtraction::AnnotationDraft
        drafts.each_with_index do |draft, ordinal|
          next unless requested_kinds.includes?(draft.kind)

          start, stop, exact = _anchor(draft.text, draft.kind, spans, content)
          body = {"text" => JSON::Any.new(draft.text), "kind" => JSON::Any.new(draft.kind)}
          draft.fields.each { |key, value| body[key] = value }
          out << Chronicle::Packs::SemanticExtraction::AnnotationDraft.new(
            FACET_BY_KIND[draft.kind], body, start, stop, exact, draft.confidence,
            metadata: {"ordinal" => JSON::Any.new(ordinal)},
          )
        end
        out
      end

      # (start, end, raw, cleaned) per non-empty line, offsets exact.
      def _line_spans(content : String, max_candidate_chars : Int32) : Array({Int32, Int32, String, String})
        spans = [] of {Int32, Int32, String, String}
        cursor = 0
        content.split(/\r\n|\r|\n/).each do |raw|
          start = content.index(raw, cursor)
          next if start.nil?

          cursor = start + raw.size
          cleaned = AnnotationExtractor._clean(raw, max_candidate_chars)
          spans << {start, start + raw.size, raw, cleaned} unless cleaned.empty?
        end
        if spans.empty? && !content.strip.empty?
          stripped = content.strip
          start = content.index(stripped) || 0
          spans << {start, start + stripped.size, stripped, AnnotationExtractor._clean(content, max_candidate_chars)}
        end
        spans
      end

      # Anchor one legacy draft to the line it came from.
      def _anchor(text : String, kind : String, spans : Array({Int32, Int32, String, String}), content : String) : {Int32, Int32, String}
        direct = content.index(text)
        if direct
          return {direct, direct + text.size, text}
        end
        needle = text.downcase
        spans.each do |start, stop, raw, cleaned|
          if needle.in?(cleaned.downcase) || cleaned.downcase.includes?(needle)
            return {start, stop, raw}
          end
        end
        start, stop, raw, _cleaned = spans[0]
        {start, stop, raw}
      end
    end
  end

  # Seed the shared registry with the structure annotation extractor (upstream
  # register_annotation_extractor runs at import time).
  Chronicle::Packs::SemanticExtraction::Extractors.register_annotation_extractor(AnnotationExtractor::StructureAnnotationExtractor.new)
end

require "json"
require "set"

module Chronicle::Packs::ActivityNormalizer
  # Versioned deterministic extractor seam for activity evidence. Ported from
  # upstream packs/activity_normalizer/extractors.py. Only the zero-key
  # structure extractor ships in v0.1.
  module Extractors
    # Small, deterministic line/structure heuristics with no provider key.
    class StructureExtractor
      property extractor_id : String = "activity.structure"
      property extractor_version : String = "0.1.0"

      PREFERENCE_RE    = /^(?:preference\s*:|i\s+(?:always\s+)?prefer\b|i\s+like\b)/i
      TASK_RE          = /^(?:todo\s*:|task\s*:|action\s*:|we\s+need\s+to\b)/i
      PROFILE_RE       = /^(?:profile\s*:|my\s+name\s+is\b|i\s+am\b)/i
      SKILL_RE         = /^skill\s*:/i
      EVAL_RE          = /^(?:evaluation\s*:|eval\s*:)|\b(?:helpful|helped|hurt|failed|worked|contradicted)\b/i
      MEMORY_PREFIX_RE = /^(?:remember\s*:|memory\s*:)/i

      def extract(content : String, metadata : Hash(String, JSON::Any), max_candidates : Int32, max_candidate_chars : Int32) : Array(CandidateDraft)
        lines = content.split(/\r\n|\r|\n/)
          .map { |line| _clean(line, max_candidate_chars) }
          .reject(&.empty?)
        lines = [_clean(content, max_candidate_chars)] if lines.empty? && !content.strip.empty?

        drafts = [] of CandidateDraft
        unless lines.empty?
          first = lines[0].gsub(MEMORY_PREFIX_RE, "").strip
          first = lines[0] if first.empty?
          drafts << CandidateDraft.new("memory", first, 0.72, {"category" => JSON::Any.new("context")})
        end

        lines.each do |line|
          drafts.concat(_drafts_for_line(line))
        end

        # One stable output for identical text/kind, preserving first occurrence.
        unique = [] of CandidateDraft
        seen = Set(String).new
        drafts.each do |draft|
          key = "#{draft.kind}\x1f#{draft.text.downcase}"
          next if seen.includes?(key)
          seen << key
          unique << draft
          break if unique.size >= max_candidates
        end
        unique
      end

      private def _drafts_for_line(line : String) : Array(CandidateDraft)
        result = [] of CandidateDraft
        if PREFERENCE_RE.matches?(line)
          text = line.gsub(/^preference\s*:\s*/i, "")
          result << CandidateDraft.new("preference", text, 0.82, {"preference" => JSON::Any.new(text)}) unless text.empty?
        end
        if TASK_RE.matches?(line)
          text = line.gsub(/^(?:todo|task|action)\s*:\s*/i, "")
          result << CandidateDraft.new("task", text, 0.8, {"title" => JSON::Any.new(text[0, 120])}) unless text.empty?
        end
        if PROFILE_RE.matches?(line)
          text = line.gsub(/^profile\s*:\s*/i, "")
          unless text.empty?
            result << CandidateDraft.new("profile", text, 0.78, {"attribute" => JSON::Any.new("profile_statement"), "value" => JSON::Any.new(text)})
          end
        end
        if SKILL_RE.matches?(line)
          text = line.gsub(/^skill\s*:\s*/i, "")
          unless text.empty?
            result << CandidateDraft.new("skill", text, 0.76, {"name" => JSON::Any.new(text[0, 120]), "description" => JSON::Any.new(text)})
          end
        end
        if EVAL_RE.matches?(line)
          text = line.gsub(/^(?:evaluation|eval)\s*:\s*/i, "")
          result << CandidateDraft.new("eval", text, 0.74, {"subject" => JSON::Any.new("source_activity"), "judgment" => JSON::Any.new(text)}) unless text.empty?
        end
        result
      end

      private def _clean(value : String, limit : Int32) : String
        value.gsub(/\s+/, " ").strip[0, limit]
      end
    end

    private REGISTRY = {} of Tuple(String, String) => StructureExtractor

    def self.register_extractor(extractor : StructureExtractor) : Nil
      key = {extractor.extractor_id, extractor.extractor_version}
      existing = REGISTRY[key]?
      raise "extractor already registered: #{key[0]}@#{key[1]}" if existing && existing != extractor
      REGISTRY[key] = extractor
    end

    def self.get_extractor(extractor_id : String, extractor_version : String) : StructureExtractor
      REGISTRY[{extractor_id, extractor_version}]? || raise KeyError.new("unknown extractor #{extractor_id}@#{extractor_version}")
    end
  end

  # Seed the registry with the zero-key structure extractor (upstream
  # register_extractor(StructureExtractor()) runs at import time).
  Extractors.register_extractor(Extractors::StructureExtractor.new)

  # Provider-neutral proposed candidate before graph materialization.
  struct CandidateDraft
    getter kind : String
    getter text : String
    getter confidence : Float64
    getter fields : Hash(String, JSON::Any)

    def initialize(kind : String, text : String, confidence : Float64 = 0.7, fields : Hash(String, JSON::Any) = {} of String => JSON::Any)
      @kind = kind
      @text = text
      @confidence = confidence
      @fields = fields
    end
  end
end

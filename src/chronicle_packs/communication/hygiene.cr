require "json"
require "digest/sha256"

module Chronicle::Packs::Communication
  # Deterministic conversation content selection before model interpretation.
  # Ported from upstream packs/communication/hygiene.py.
  module HygienePatterns
    FILTER_VERSION = "communication.hygiene@0.1.0"

    QUOTED_START    = /^\s*On .{0,240}wrote:\s*$/i
    FORWARDED_START = /^\s*-{2,}\s*(original|forwarded) message\s*-{2,}\s*$/i
    SIGNATURE       = /^\s*(--\s*|sent from my\b)/i
    BOILERPLATE     = /\b(unsubscribe|manage (your )?preferences|view (this )?(email )?in (your )?browser|privacy policy|email preferences)\b/i
    TRACKING        = /<img\b[^>]*(?:width=["']?1|height=["']?1|tracking)[^>]*>/i
  end

  def self._sha(text : String) : String
    Digest::SHA256.hexdigest(text)
  end

  # Deterministic hygiene result: display text plus exact evidence selectors.
  struct HygieneResult
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter display_content : String
    getter interpretation_content : String
    getter interpretation_state : String
    getter suppression_counts : Hash(String, Int32)
    getter selections : Array(Hash(String, JSON::Any))
    getter injection_flags : Array(String)
    getter? truncated : Bool

    def initialize(
      @display_content : String, @interpretation_content : String,
      @interpretation_state : String,
      @suppression_counts : Hash(String, Int32),
      @selections : Array(Hash(String, JSON::Any)),
      @injection_flags : Array(String), @truncated : Bool,
    )
    end

    define_copy_with
  end

  # Return display text plus exact evidence selectors for interpretation.
  # Display text remains inert data for typed clients. Model-eligible text
  # is represented as exact contiguous selectors into the authoritative
  # evidence; no cleaned/paraphrased copy can become an annotation anchor.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream line-classification branches
  def self.select_conversation_content(
    body : String,
    evidence_offset : Int32 = 0,
    injection_flags : Array(String)? = nil,
    notification : Bool = false,
    max_selected_chars : Int32 = 12_000,
  ) : HygieneResult
    counts = {
      "quoted_history" => 0,
      "signature"      => 0,
      "boilerplate"    => 0,
      "tracking"       => 0,
      "notification"   => 0,
      "injection"      => (injection_flags || [] of String).size,
    } of String => Int32
    kept = [] of Tuple(Int32, Int32, String)
    cursor = 0
    stopped = false

    split_lines_keepends(body).each do |raw_line, start_offset|
      line = raw_line.rstrip("\r\n")
      start = start_offset
      cursor = start_offset + raw_line.size
      if stopped
        counts["quoted_history"] += 1 unless line.strip.empty?
        next
      end
      if HygienePatterns::QUOTED_START.matches?(line) || HygienePatterns::FORWARDED_START.matches?(line)
        counts["quoted_history"] += 1
        stopped = true
        next
      end
      if line.lstrip.starts_with?(">")
        counts["quoted_history"] += 1
        next
      end
      if HygienePatterns::SIGNATURE.matches?(line)
        counts["signature"] += 1
        stopped = true
        next
      end
      if HygienePatterns::BOILERPLATE.matches?(line)
        counts["boilerplate"] += 1
        next
      end
      if HygienePatterns::TRACKING.matches?(line)
        counts["tracking"] += 1
        next
      end
      unless line.strip.empty?
        left = line.size - line.lstrip.size
        right = line.rstrip.size
        exact = line[left, right - left]
        kept << {start + left, start + right, exact}
      end
    end

    display = kept.map(&.[2]).join("\n").strip
    if notification
      counts["notification"] = 1
      return HygieneResult.new(display, "", "suppressed", counts, [] of Hash(String, JSON::Any), injection_flags || [] of String, false)
    end
    if injection_flags && !injection_flags.empty?
      return HygieneResult.new(display, "", "held", counts, [] of Hash(String, JSON::Any), injection_flags, false)
    end
    if display.empty?
      return HygieneResult.new("", "", "empty", counts, [] of Hash(String, JSON::Any), [] of String, false)
    end

    selections = [] of Hash(String, JSON::Any)
    selected = [] of String
    remaining = max_selected_chars
    truncated = false
    kept.each do |start, _end, exact|
      if remaining <= 0
        truncated = true
        break
      end
      chosen = exact[0, remaining]
      if chosen.size < exact.size
        truncated = true
      end
      unless chosen.empty?
        selections << {
          "start"      => JSON::Any.new(evidence_offset + start),
          "end"        => JSON::Any.new(evidence_offset + start + chosen.size),
          "exact_hash" => JSON::Any.new(_sha(chosen)),
        }
        selected << chosen
        remaining -= chosen.size
      end
      break if truncated
    end
    interpretation = selected.join("\n")
    HygieneResult.new(
      display,
      interpretation,
      interpretation.empty? ? "empty" : "ready",
      counts,
      selections,
      [] of String,
      truncated,
    )
  end

  # Split a body into its raw lines (terminator kept) with the char start
  # offset of each line, mirroring Python's splitlines(keepends=True).
  def self.split_lines_keepends(body : String) : Array(Tuple(String, Int32))
    lines = [] of Tuple(String, Int32)
    offset = 0
    body.each_line(chomp: false) do |line|
      lines << {line, offset}
      offset += line.size
    end
    lines
  end
end

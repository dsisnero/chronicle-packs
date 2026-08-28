module Chronicle::Packs
  # Runtime-version preflight for the pack library (H2). Ported from
  # upstream packs/_preflight.py.
  #
  # Why this exists: importing these packs against a pre-v1.9 activegraph
  # runtime dies mid-import with an unrelated `CapabilityDecl.__init__() got
  # an unexpected keyword argument 'action_class'` — a fail-weird that says
  # nothing about the actual problem. This module turns that incident class
  # into one loud, actionable error.
  #
  # What decides pass/fail: FEATURE DETECTION, not the version string. In
  # the Crystal port the "runtime" is the chronicle shard, compiled in — so
  # `runtime_supports_contract` introspects chronicle's `CapabilityDecl` at
  # compile time: it must carry the `action_class` field (CONTRACT v1.9 #1).
  #
  # The doctor (`doctor.py`, Phase 7) surfaces the same probe
  # diagnostically; keep the two in sync by keeping the logic here.
  module Preflight
    # Minimum runtime the pack library's contract requires (CONTRACT v1.9 —
    # canonical action_class authority).
    REQUIRED_FLOOR = "1.9"

    # The v1.9 feature the packs actually import against: `CapabilityDecl`
    # grew the `action_class` field (CONTRACT v1.9 #1).
    FLOOR_FEATURE = "action_class"

    # Compile-time feature detect: does the chronicle runtime's
    # `CapabilityDecl` carry the `action_class` field?
    FLOOR_SUPPORTED = {{ Chronicle::Packs::CapabilityDecl.has_method?("action_class") }}

    # The installed runtime predates this pack library's contract. Raised
    # so the failure names the fix instead of surfacing as an unrelated
    # error mid-import.
    class RuntimePreflightError < Exception
    end

    # The one error message for a too-old runtime, verbatim per H2.
    def self.preflight_message(found_version : String) : String
      "activegraph >= #{REQUIRED_FLOOR} is required (found #{found_version}). " \
      "The PyPI release is older than\n" \
      "this pack library's contract. Install from source until v1.9 publishes:\n" \
      "  pip install -e \"./activegraph-src[llm]\"   (clone as activegraph-src — a dir\n" \
      "  named activegraph would shadow the package). See README quickstart."
    end

    # True when the installed runtime carries the v1.9 contract floor.
    #
    # Feature-detects `CapabilityDecl.action_class` rather than trusting
    # the version string (editable installs lie in both directions).
    def self.runtime_supports_contract : Bool
      FLOOR_SUPPORTED
    end

    # The installed runtime's self-reported version, for messages only.
    def self.found_runtime_version : String
      Chronicle::VERSION
    end

    # Raise RuntimePreflightError if the runtime predates the contract
    # floor; return silently otherwise.
    def self.assert_runtime_compatible : Nil
      return if runtime_supports_contract
      raise RuntimePreflightError.new(preflight_message(found_runtime_version))
    end
  end
end

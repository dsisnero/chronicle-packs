require "json"

module Chronicle::Packs
  # Shared closed string-literal sets modeled as enums (AGENTS.md). Non-flags
  # enums serialize as the member name via String#underscore, so members are
  # named as the CamelCase of the upstream string and to_json/from_json
  # round-trip to the exact upstream value, while parse?/parse give
  # validation and .each/question methods give iteration and case-matching.

  enum SourceCategory
    Communication
    Rhythm
    AiActivity
    CodeWork
    LocalKnowledge
    ToolAutomation
    OutcomeEvaluation

    # The upstream wire string (member name underscored).
    def wire : String
      to_s.underscore
    end

    def self.from_wire(value : String) : self
      parse?(value) || raise ArgumentError.new("unknown #{name} #{value.inspect}")
    end
  end

  enum ConnectionPath
    Export
    Mcp
    Composio
    Native
    Local
    Pack
    Manual

    def wire : String
      to_s.underscore
    end

    def self.from_wire(value : String) : self
      parse?(value) || raise ArgumentError.new("unknown #{name} #{value.inspect}")
    end
  end

  enum ReplayMode
    Inline
    Artifact
    ReferenceOnly

    def wire : String
      to_s.underscore
    end

    def self.from_wire(value : String) : self
      parse?(value) || raise ArgumentError.new("unknown #{name} #{value.inspect}")
    end
  end

  enum SurfaceStatus
    Connected
    Settling
    Settled
    Stale
    Revoked
    Failed

    def wire : String
      to_s.underscore
    end

    def self.from_wire(value : String) : self
      parse?(value) || raise ArgumentError.new("unknown #{name} #{value.inspect}")
    end
  end
end

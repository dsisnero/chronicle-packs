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
  end

  enum ConnectionPath
    Export
    Mcp
    Composio
    Native
    Local
    Pack
    Manual
  end

  enum ReplayMode
    Inline
    Artifact
    ReferenceOnly
  end

  enum SurfaceStatus
    Connected
    Settling
    Settled
    Stale
    Revoked
    Failed
  end

  # Shared outcome-derived reliability verdict (eval_outcome, memory_gateway).
  enum ReliabilityVerdict
    Supported
    Weak
    Harmful
    Stale
  end
end

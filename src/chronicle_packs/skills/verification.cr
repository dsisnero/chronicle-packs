require "json"
require "digest/sha256"

module Chronicle::Packs::Skills
  # Replay verification for promoted skill versions (P6).
  #
  # The full `verify_skill_replay_fn` re-runs a recorded invocation inside a
  # runtime FORK (`runtime.fork`) and compares the governed shape. chronicle
  # has not yet ported `Runtime#fork` (it has `ReplayEngine#replay` instead),
  # so the fork-trial step is DEFERRED. The portable pieces below — the
  # error type, the recorded-usage lookup, and the ADR 0015 lineage-gap
  # check — are ported so the contract is ready when fork lands.

  # Replay evidence cannot support a replay.verified claim (ADR 0015).
  class SkillReplayIncompleteError < Chronicle::Packs::PackError
  end

  # The earliest recorded usage of this exact version, or nil.
  def self._recorded_usage(graph : Chronicle::GraphProjection, skill : Chronicle::GraphObject) : Chronicle::GraphObject?
    graph.objects(type: "skill_usage").find { |obj| JSON.parse(obj.data)["skill_version_id"]?.try(&.as_s?) == skill.id }
  end

  # Source evidence refs whose recorded lineage forbids a replay claim.
  def self._lineage_gaps(graph : Chronicle::GraphProjection, skill : Chronicle::GraphObject) : Array(String)
    gaps = [] of String
    (JSON.parse(skill.data)["source_evidence_refs"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String).each do |ref|
      evidence = graph.get_object(ref)
      next if evidence.nil? # opaque provenance ref; nothing recorded to attest

      data = JSON.parse(evidence.data)
      metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
      acquisition = data["acquisition"]?.try(&.as_h) || metadata["acquisition"]?.try(&.as_h) || {} of String => JSON::Any
      replay_complete = data["replay_complete"]?.try(&.as_bool?)
      replay_complete = metadata["replay_complete"]?.try(&.as_bool?) if replay_complete.nil?
      if replay_complete == false
        gaps << ref
      elsif (acquisition["replay_mode"]?.try(&.as_s?)) == "reference_only"
        gaps << ref
      end
    end
    gaps
  end
end

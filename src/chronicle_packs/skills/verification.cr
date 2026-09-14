require "json"
require "digest/sha256"

module Chronicle::Packs::Skills
  # Replay verification for promoted skill versions (P6).
  #
  # The full `verify_skill_replay_fn` re-runs a recorded invocation inside a
  # durable runtime fork and compares only its governed shape. The fork is
  # evidence: it never writes replay usage into the parent graph.

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

  # Earn replay.verified for one promoted skill version. The contract key is
  # (skill_id, version), not the graph object's incidental id. A verifier
  # failure is evidence that the claim cannot be made, never a skipped check.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful four-stage replay verification
  def self.verify_skill_replay_fn(graph : Chronicle::GraphProjection, runtime : Chronicle::Runtime(M), skill_version_id : String, actor : String = "skills") : Hash(String, JSON::Any) forall M
    skill = _find_skill_by_object_or_identity(graph, skill_version_id)
    raise Chronicle::Packs::PackError.new("unknown skill version") if skill.nil?

    data = JSON.parse(skill.data).as_h
    status = data["status"]?.try(&.as_s?) || "candidate"
    unless status == "promoted"
      raise Chronicle::Packs::PackError.new("replay verification applies to promoted skill versions only; this version is #{status.inspect}")
    end

    definition = _definition(
      data["name"]?.try(&.as_s?) || "", data["version"]?.try(&.as_s?) || "",
      data["description"]?.try(&.as_s?) || "",
      (data["trigger_conditions"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_s),
      (data["required_capabilities"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_s),
      (data["contraindications"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_s),
    )
    recomputed = Digest::SHA256.hexdigest(_canonical_json(JSON::Any.new(definition)))
    if recomputed != data["definition_hash"]?.try(&.as_s?)
      raise SkillReplayIncompleteError.new("skill #{skill.id.inspect} definition no longer hashes to its recorded identity — replay check failed, not skipped")
    end

    usage = _recorded_usage(graph, skill)
    if usage.nil?
      raise SkillReplayIncompleteError.new("skill #{skill.id.inspect} has no recorded usage; a replay.verified claim needs a recorded trial to re-run")
    end
    usage_data = JSON.parse(usage.data).as_h

    gaps = _lineage_gaps(graph, skill)
    unless gaps.empty?
      raise SkillReplayIncompleteError.new("skill #{skill.id.inspect} has reference_only / replay-incomplete source lineage #{gaps}; ADR 0015: such lineage may not support a replay.verified claim")
    end

    version = data["version"]?.try(&.as_s?) || ""
    subject_id = data["skill_id"]?.try(&.as_s?) || ""
    prior = graph.events.find do |event|
      event.type == "replay.verified" &&
        JSON.parse(event.payload)["subject_id"]?.try(&.as_s?) == subject_id &&
        JSON.parse(event.payload)["subject_version"]?.try(&.as_s?) == version
    end
    return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "event_id" => JSON::Any.new(prior.id)} if prior

    anchor = usage_data["used_event_id"]?.try(&.as_s?) || ""
    anchor = graph.events.last?.try(&.id) || "" if anchor.empty? || anchor == "behavior-emitted"
    raise SkillReplayIncompleteError.new("skill #{skill.id.inspect} has no recorded event at which to fork") if anchor.empty?
    fork = runtime.fork(anchor, label: "skill-replay:#{skill.id}")
    fork_graph = fork.graph || raise SkillReplayIncompleteError.new("fork-trial has no graph")
    replay_usage_id = "replay::#{usage_data["usage_id"]?.try(&.as_s?) || ""}"
    replayed = invoke_skill_fn(
      fork_graph, data["name"]?.try(&.as_s?) || "", version,
      replay_usage_id, "replay::#{usage_data["execution_ref"]?.try(&.as_s?) || ""}",
      "trial", actor,
      {"replay_of" => JSON::Any.new(usage_data["usage_id"]?.try(&.as_s?) || "")},
      is_fixture: usage_data["is_fixture"]?.try(&.as_bool?) || false,
    )["usage"].as_h["data"].as_h

    mismatches = ["skill_id", "skill_version", "required_capabilities"].select do |field|
      usage_data[field]? != replayed[field]?
    end
    unless mismatches.empty?
      raise SkillReplayIncompleteError.new("fork re-run of skill #{skill.id.inspect} diverged from the recorded usage fields: #{mismatches.join(", ")}")
    end

    event = _emit_event(graph, "replay.verified", {
      "subject_id"        => JSON::Any.new(subject_id),
      "subject_version"   => JSON::Any.new(version),
      "subject_type"      => JSON::Any.new("skill_version"),
      "subject_object_id" => JSON::Any.new(skill.id),
      "method"            => JSON::Any.new("fork_trial_rerun"),
      "recorded_usage_id" => usage_data["usage_id"]? || JSON::Any.new(""),
      "replay_usage_id"   => JSON::Any.new(replay_usage_id),
      "fork_run_id"       => JSON::Any.new(fork.run_id),
      "checks"            => JSON::Any.new([
        JSON::Any.new({"check" => JSON::Any.new("definition_hash"), "passed" => JSON::Any.new(true)}),
        JSON::Any.new({"check" => JSON::Any.new("lineage_replay_complete"), "passed" => JSON::Any.new(true)}),
        JSON::Any.new({"check" => JSON::Any.new("fork_trial_rerun"), "passed" => JSON::Any.new(true)}),
      ]),
      "actor"      => JSON::Any.new(actor),
      "is_fixture" => data["is_fixture"]? || JSON::Any.new(false),
    })
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "event_id" => JSON::Any.new(event.id)}
  end
end

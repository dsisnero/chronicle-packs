require "json"

module Chronicle::Packs::Skills
  # Graph-composed behaviors for skill proposals, evaluations, and
  # eligibility. Ported from upstream packs/skills/behaviors.py.

  # Evidence refs for a normalizer skill candidate.
  def self._candidate_evidence_refs(data : JSON::Any, candidate_id : String) : Array(String)
    refs = [] of String
    [candidate_id, data["evidence_id"]?.try(&.as_s?), data["revision_id"]?.try(&.as_s?), data["extraction_record_id"]?.try(&.as_s?)].each do |value|
      refs << value if value
    end
    refs
  end

  # Authoring metadata for a normalizer skill candidate.
  def self._candidate_author_metadata(data : JSON::Any) : Hash(String, JSON::Any)
    author_meta = {} of String => JSON::Any
    if extractor_id = data["extractor_id"]?
      author_meta["extractor_id"] = extractor_id
    end
    if extractor_version = data["extractor_version"]?
      author_meta["extractor_version"] = extractor_version
    end
    if config_id = data["extraction_config_id"]?
      author_meta["extraction_config_id"] = config_id
    end
    author_meta
  end

  # Author a skill artifact from a normalizer candidate.
  def self._author_from_candidate(graph : Chronicle::GraphProjection, data : JSON::Any, candidate_id : String, metadata : Hash(String, JSON::Any), settings : SkillsSettings) : Nil
    author_skill_fn(
      graph,
      (data["name"]?.try(&.as_s?) || data["text"]?.try(&.as_s?) || "")[0, 120],
      metadata["skill_version"]?.try(&.as_s?) || settings.default_candidate_version,
      data["description"]?.try(&.as_s?) || data["text"]?.try(&.as_s?) || "",
      metadata["trigger_conditions"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      metadata["required_capabilities"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      metadata["contraindications"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      _candidate_evidence_refs(data, candidate_id),
      candidate_id,
      "activity_normalizer",
      metadata["is_fixture"]?.try(&.as_bool?) || false,
      _candidate_author_metadata(data),
    )
  end

  # Turn a normalizer skill candidate into a provenance-backed v0 artifact.
  @[Chronicle::Packs::Annotations::Behavior(name: "skill_candidate_author", on: ["object.created"], where: {"type" => "skill_candidate"}, creates: ["skill"])]
  def skill_candidate_author(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SkillsSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload)
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?

    data = payload["data"]?
    return if data.nil?
    return unless (data["status"]?.try(&.as_s?)) == "candidate"

    _author_from_candidate(graph, data, candidate_id, data["metadata"]?.try(&.as_h) || {} of String => JSON::Any, settings)
  end

  # Link a Core evaluation carrying usage provenance to that exact usage.
  @[Chronicle::Packs::Annotations::Behavior(name: "skill_evaluation_linker", on: ["object.created"], where: {"type" => "evaluation"}, creates: ["skill_evaluation_link"])]
  def skill_evaluation_linker(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SkillsSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload)
    evaluation_id = payload["id"]?.try(&.as_s?)
    return if evaluation_id.nil?

    data = payload["data"]?
    return if data.nil?

    usage_id = data["metadata"]?.try(&.["usage_id"]?.try(&.as_s?)) || ""
    return if usage_id.empty?

    link_skill_evaluation_fn(graph, usage_id, evaluation_id)
  end

  # Demote a skill whose reliability became harmful/stale.
  def self._demote_for_reliability(graph : Chronicle::GraphProjection, skill : Chronicle::GraphObject, skill_data : Hash(String, JSON::Any), verdict : String, outcome_event_id : String?) : Nil
    _emit_event(graph, "skill.demoted", {
      "artifact_id"               => JSON::Any.new(skill.id),
      "skill_id"                  => skill_data["skill_id"],
      "skill_version"             => skill_data["version"],
      "reason"                    => JSON::Any.new("reliability became #{verdict}"),
      "actor"                     => JSON::Any.new("eval_outcome"),
      "outcome_evidence_event_id" => JSON::Any.new(outcome_event_id),
      "is_fixture"                => skill_data["is_fixture"]? || JSON::Any.new(false),
    })
    metadata = skill_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    metadata["demoted_by_reliability"] = JSON::Any.new(true)
    merged = skill_data
    merged["status"] = JSON::Any.new("demoted")
    merged["demotion_reason"] = JSON::Any.new("reliability became #{verdict}")
    merged["metadata"] = JSON::Any.new(metadata)
    graph.patch_object(skill.id, merged.to_json)
  end

  # A promotion-history entry for a re-promotion.
  def self._reliability_history_entry(promoted : Chronicle::Event, outcome_event_id : String?) : PromotionHistoryEntry
    PromotionHistoryEntry.new(
      event_id: promoted.id, evidence_id: outcome_event_id,
      rationale: "reliability recovered to supported", actor: "eval_outcome",
      prior_status: "demoted", new_status: "promoted",
    )
  end

  # Re-promote a reliability-demoted skill whose verdict recovered.
  def self._repromote_for_reliability(graph : Chronicle::GraphProjection, skill : Chronicle::GraphObject, skill_data : Hash(String, JSON::Any), outcome_event_id : String?) : Nil
    promoted = _emit_event(graph, "skill.promoted", {
      "artifact_id"       => JSON::Any.new(skill.id),
      "skill_id"          => skill_data["skill_id"],
      "skill_version"     => skill_data["version"],
      "evidence_id"       => JSON::Any.new(outcome_event_id),
      "rationale"         => JSON::Any.new("reliability recovered to supported"),
      "actor"             => JSON::Any.new("eval_outcome"),
      "prior_status"      => JSON::Any.new("demoted"),
      "reliability_basis" => JSON::Any.new("outcome projection"),
      "is_fixture"        => skill_data["is_fixture"]? || JSON::Any.new(false),
    })
    history = _read_history(skill_data)
    history << _reliability_history_entry(promoted, outcome_event_id)
    metadata = skill_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    metadata["demoted_by_reliability"] = JSON::Any.new(false)
    merged = skill_data
    merged["status"] = JSON::Any.new("promoted")
    merged["demotion_reason"] = JSON::Any.new(nil)
    merged["promotion_history"] = JSON.parse(history.to_json)
    merged["metadata"] = JSON::Any.new(metadata)
    graph.patch_object(skill.id, merged.to_json)
  end

  # Resolve the skill artifact a reliability event refers to, or nil.
  def self._reliability_skill(payload : JSON::Any, graph : Chronicle::GraphProjection) : Chronicle::GraphObject?
    return nil unless (payload["artifact_type"]?.try(&.as_s?)) == "skill_version"

    skill = graph.get_object(payload["artifact_id"]?.try(&.as_s?) || "")
    return nil if skill.nil? || skill.type != "skill"

    skill
  end

  # Apply generic reliability to eligibility without deleting skill history.
  @[Chronicle::Packs::Annotations::Behavior(name: "skill_reliability_eligibility", on: ["reliability.changed"])]
  def skill_reliability_eligibility(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SkillsSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload)
    skill = _reliability_skill(payload, graph)
    return if skill.nil?

    verdict = payload["verdict"]?.try(&.as_s?) || ""
    outcome_event_id = payload["outcome_event_id"]?.try(&.as_s?)
    skill_data = JSON.parse(skill.data).as_h
    current = skill_data["status"]?.try(&.as_s?) || "candidate"
    metadata = skill_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any

    if verdict.in?({"harmful", "stale"}) && current.in?({"candidate", "promoted"})
      _demote_for_reliability(graph, skill, skill_data, verdict, outcome_event_id)
    elsif verdict == "supported" && current == "demoted" && (metadata["demoted_by_reliability"]?.try(&.as_bool?) || false)
      _repromote_for_reliability(graph, skill, skill_data, outcome_event_id)
    end
  end

  # Maintain the skill object's neutral outcome tally from canonical outcomes.
  @[Chronicle::Packs::Annotations::Behavior(name: "skill_outcome_summary", on: ["outcome.helped", "outcome.hurt", "outcome.neutral"])]
  def skill_outcome_summary(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SkillsSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload)
    return unless (payload["artifact_type"]?.try(&.as_s?)) == "skill_version"

    skill = graph.get_object(payload["artifact_id"]?.try(&.as_s?) || "")
    return if skill.nil? || skill.type != "skill"

    kind = event.type.sub("outcome.", "")
    skill_data = JSON.parse(skill.data).as_h
    summary = skill_data["outcome_summary"]?.try(&.as_h) || {} of String => JSON::Any
    summary[kind] = JSON::Any.new((summary[kind]?.try(&.as_i?) || 0) + 1)
    merged = skill_data
    merged["outcome_summary"] = JSON::Any.new(summary)
    graph.patch_object(skill.id, merged.to_json)
  end
end

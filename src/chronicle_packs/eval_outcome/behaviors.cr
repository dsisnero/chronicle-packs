require "json"

module Chronicle::Packs::EvalOutcome
  # Thin capture behaviors and the artifact reliability projector. Ported
  # from upstream packs/eval_outcome/behaviors.py.

  # Judgment -> terminal outcome event mapping for evaluation capture.
  module TerminalJudgments
    MAP = {
      "accepted"               => "outcome.helped",
      "completed_successfully" => "outcome.helped",
      "done"                   => "outcome.helped",
      "rejected"               => "outcome.hurt",
      "failed"                 => "outcome.hurt",
      "completed_neutrally"    => "outcome.neutral",
      "neutral"                => "outcome.neutral",
      "not_relevant"           => "outcome.neutral",
    }
  end

  # The verdict and retrieval multiplier for an outcome event kind.
  def self._verdict_and_multiplier(event_type : String, settings : EvalOutcomeSettings) : {Chronicle::Packs::ReliabilityVerdict, Float64}
    case event_type
    when "outcome.helped"                       then {Chronicle::Packs::ReliabilityVerdict::Supported, settings.supported_retrieval_multiplier}
    when "outcome.hurt", "outcome.contradicted" then {Chronicle::Packs::ReliabilityVerdict::Harmful, settings.harmful_retrieval_multiplier}
    when "outcome.stale", "outcome.superseded"  then {Chronicle::Packs::ReliabilityVerdict::Stale, settings.stale_retrieval_multiplier}
    else
      {Chronicle::Packs::ReliabilityVerdict::Weak, settings.weak_retrieval_multiplier}
    end
  end

  # The current reliability projection for an artifact, if any.
  def self._existing_reliability(graph : Chronicle::GraphProjection, artifact_id : String) : Chronicle::GraphObject?
    graph.objects(type: "artifact_reliability").find { |obj| JSON.parse(obj.data)["artifact_id"]?.try(&.as_s?) == artifact_id }
  end

  # The prior tallies and evidence ids of an existing projection.
  def self._reliability_tallies(existing : Chronicle::GraphObject?) : {Hash(String, Int32), Array(String)}
    tallies = {} of String => Int32
    evidence_ids = [] of String
    if existing
      existing_data = JSON.parse(existing.data)
      (existing_data["tallies"]?.try(&.as_h) || {} of String => JSON::Any).each { |key, value| tallies[key] = value.as_i }
      evidence_ids = existing_data["evidence_event_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    end
    {tallies, evidence_ids}
  end

  # Build the updated reliability projection for one outcome event.
  def self._build_reliability_update(
    payload : JSON::Any,
    event : Chronicle::Event,
    settings : EvalOutcomeSettings,
    tallies : Hash(String, Int32),
    evidence_ids : Array(String),
  ) : ArtifactReliability
    kind = event.type.sub("outcome.", "")
    tallies[kind] = (tallies[kind]? || 0) + 1
    evidence_ids << event.id unless evidence_ids.includes?(event.id)
    verdict, multiplier = _verdict_and_multiplier(event.type, settings)

    ArtifactReliability.new(
      artifact_id: payload["artifact_id"].as_s,
      artifact_type: payload["artifact_type"].as_s,
      artifact_version: payload["artifact_version"]?.try(&.as_s?),
      tallies: ReliabilityTallies.new(
        helped: tallies["helped"]? || 0, hurt: tallies["hurt"]? || 0, neutral: tallies["neutral"]? || 0,
        contradicted: tallies["contradicted"]? || 0, stale: tallies["stale"]? || 0, superseded: tallies["superseded"]? || 0,
      ),
      verdict: verdict,
      eligible: !verdict.in?({Chronicle::Packs::ReliabilityVerdict::Harmful, Chronicle::Packs::ReliabilityVerdict::Stale}),
      retrieval_multiplier: multiplier,
      latest_outcome_type: kind,
      latest_outcome_event_id: event.id,
      latest_evaluation_id: payload["evaluation_id"]?.try(&.as_s?),
      latest_usage_id: payload["usage_id"]?.try(&.as_s?),
      evidence_event_ids: evidence_ids,
      metadata: {
        "latest_rationale" => payload["rationale"]? || JSON::Any.new(""),
        "latest_actor"     => payload["actor"]? || JSON::Any.new(event.actor),
      },
    )
  end

  # Emit the reliability.changed receipt for a projection update.
  def self._emit_reliability_changed(graph : Chronicle::GraphProjection, payload : JSON::Any, event : Chronicle::Event, update : ArtifactReliability, verdict : Chronicle::Packs::ReliabilityVerdict, multiplier : Float64, kind : String, evidence_ids : Array(String)) : Nil
    _emit_event(graph, "reliability.changed", {
      "artifact_id"             => JSON::Any.new(update.artifact_id),
      "artifact_type"           => JSON::Any.new(update.artifact_type),
      "artifact_version"        => update.artifact_version ? JSON::Any.new(update.artifact_version) : JSON::Any.new(nil),
      "tallies"                 => JSON::Any.new(update.tallies.to_json),
      "verdict"                 => JSON.parse(verdict.to_json),
      "eligible"                => JSON::Any.new(!verdict.in?({Chronicle::Packs::ReliabilityVerdict::Harmful, Chronicle::Packs::ReliabilityVerdict::Stale})),
      "retrieval_multiplier"    => JSON::Any.new(multiplier),
      "latest_outcome_type"     => JSON::Any.new(kind),
      "latest_outcome_event_id" => JSON::Any.new(event.id),
      "latest_evaluation_id"    => payload["evaluation_id"]? || JSON::Any.new(nil),
      "latest_usage_id"         => payload["usage_id"]? || JSON::Any.new(nil),
      "evidence_event_ids"      => JSON::Any.new(evidence_ids.map { |id| JSON::Any.new(id) }),
      "outcome_event_id"        => JSON::Any.new(event.id),
      "evidence_revision_id"    => payload["evidence_revision_id"]? || JSON::Any.new(nil),
      "metadata"                => JSON::Any.new(update.metadata),
    }, "eval_outcome")
  end

  # Project recency-aware artifact reliability from canonical outcomes.
  @[Chronicle::Packs::Annotations::Behavior(name: "artifact_reliability_projector", on: ["outcome.contradicted", "outcome.helped", "outcome.hurt", "outcome.neutral", "outcome.stale", "outcome.superseded"], creates: ["artifact_reliability"])]
  def artifact_reliability_projector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EvalOutcomeSettings) : Nil
    return if !settings.enabled?

    payload = JSON.parse(event.payload)
    artifact_id = payload["artifact_id"]?.try(&.as_s?) || ""
    artifact_type = payload["artifact_type"]?.try(&.as_s?) || ""
    return if artifact_id.empty? || artifact_type.empty?

    existing = _existing_reliability(graph, artifact_id)
    tallies, evidence_ids = _reliability_tallies(existing)
    update = _build_reliability_update(payload, event, settings, tallies, evidence_ids)
    kind = event.type.sub("outcome.", "")
    verdict, multiplier = _verdict_and_multiplier(event.type, settings)
    _emit_reliability_changed(graph, payload, event, update, verdict, multiplier, kind, evidence_ids)

    if existing.nil?
      reliability = graph.add_object("artifact_reliability", update.to_json)
    else
      graph.patch_object(existing.id, update.to_json)
      reliability = existing
    end

    outcome_record = graph.objects(type: "outcome_record").find { |obj| JSON.parse(obj.data)["outcome_event_id"]?.try(&.as_s?) == event.id }
    if outcome_record
      begin
        graph.add_relation(outcome_record.id, reliability.id, "updates_reliability")
      rescue
      end
    end
  end

  # Capture a memory contradiction as a maintenance outcome.
  def self._capture_contradiction(graph : Chronicle::GraphProjection, data : JSON::Any, metadata : Hash(String, JSON::Any), evaluation_id : String) : Nil
    return if (evidence_revision_id = metadata["evidence_revision_id"]?.try(&.as_s?)).nil?

    record_maintenance_outcome_fn(
      graph, "outcome.contradicted", data["subject_id"]?.try(&.as_s?) || "", data["subject_type"]?.try(&.as_s?) || "",
      data["rationale"]?.try(&.as_s?) || "contradiction finding",
      data["evaluator"]?.try(&.as_s?) || "memory_layer",
      artifact_version: metadata["artifact_version"]?.try(&.as_s?),
      evidence_revision_id: evidence_revision_id,
      evaluation_id: evaluation_id,
      source_context: metadata["source_context"]?.try(&.as_h) || {} of String => JSON::Any,
    )
  end

  # Capture a terminal outcome from a gateway/task/skill evaluation.
  def self._capture_terminal(graph : Chronicle::GraphProjection, data : JSON::Any, metadata : Hash(String, JSON::Any), evaluation_id : String, judgment : String) : Nil
    event_type = TerminalJudgments::MAP[judgment]?
    return if event_type.nil?

    record_terminal_outcome_fn(
      graph, event_type, evaluation_id,
      data["rationale"]?.try(&.as_s?) || judgment,
      data["evaluator"]?.try(&.as_s?) || "evaluation_capture",
      usage_id: metadata["usage_id"]?.try(&.as_s?),
      artifact_id: metadata["artifact_id"]?.try(&.as_s?),
      artifact_type: metadata["artifact_type"]?.try(&.as_s?),
      artifact_version: metadata["artifact_version"]?.try(&.as_s?),
      source_context: metadata["source_context"]?.try(&.as_h) || {} of String => JSON::Any,
      is_fixture: metadata["is_fixture"]?.try(&.as_bool?) || false,
    )
  end

  # The evaluation context for outcome capture, or nil.
  def self._capture_context(event : Chronicle::Event, settings : EvalOutcomeSettings) : NamedTuple(evaluation_id: String, data: JSON::Any)?
    return nil if !settings.enabled?

    payload = JSON.parse(event.payload)
    evaluation_id = payload["id"]?.try(&.as_s?)
    return nil if evaluation_id.nil?

    data = payload["data"]?
    return nil if data.nil?

    {evaluation_id: evaluation_id, data: data}
  end

  # Capture deterministic gateway, task, skill, and contradiction judgments.
  @[Chronicle::Packs::Annotations::Behavior(name: "evaluation_outcome_capture", on: ["object.created"], where: {"type" => "evaluation"}, creates: ["outcome_record"])]
  def evaluation_outcome_capture(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EvalOutcomeSettings) : Nil
    context = _capture_context(event, settings)
    return if context.nil?

    data = context[:data]
    subject_type = data["subject_type"]?.try(&.as_s?) || ""
    judgment = data["judgment"]?.try(&.as_s?) || ""
    metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any

    if judgment == "contradicted" && subject_type.in?({"memory_item", "memory_claim"})
      _capture_contradiction(graph, data, metadata, context[:evaluation_id])
      return
    end

    allowed_subject = subject_type.in?({"task", "capability_result"}) ||
                      (subject_type == "skill_usage" && (metadata["capture_outcome"]?.try(&.as_bool?) || false))
    return if !allowed_subject

    _capture_terminal(graph, data, metadata, context[:evaluation_id], judgment)
  end
end

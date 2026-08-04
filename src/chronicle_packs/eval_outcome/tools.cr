require "json"
require "digest/sha256"

module Chronicle::Packs::EvalOutcome
  # Outcome capture, correction, and reliability queries. Ported from
  # upstream packs/eval_outcome/tools.py. The `*_fn` functions take the
  # graph explicitly; the declared Chronicle::Tool wrappers read a graph
  # bound by the host.

  # The canonical outcome event kinds. Nested module so the DSL's `pack`
  # macro (which assumes every direct constant is a type) doesn't trip over
  # the set constants.
  module Events
    TERMINAL    = Set{"outcome.helped", "outcome.hurt", "outcome.neutral"}
    MAINTENANCE = Set{"outcome.contradicted", "outcome.stale", "outcome.superseded"}
    OUTCOME     = TERMINAL | MAINTENANCE
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil
  class_property event_seq : UInt64 = 0

  def self._stable_id(prefix : String, *parts : String) : String
    material = parts.join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any), actor : String) : Chronicle::Event
    seq = (self.event_seq += 1)
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{event_type.gsub('.', '_')}_#{seq}",
      type: event_type, actor: actor, caused_by: nil,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
  end

  def self._objects(reader : Chronicle::GraphProjection, object_type : String) : Array(Chronicle::GraphObject)
    reader.objects(type: object_type)
  end

  def self._get_object(reader : Chronicle::GraphProjection, object_id : String) : Chronicle::GraphObject?
    reader.get_object(object_id)
  end

  def self._object_json(obj : Chronicle::GraphObject) : JSON::Any
    JSON::Any.new({"id" => JSON::Any.new(obj.id), "type" => JSON::Any.new(obj.type), "data" => JSON.parse(obj.data)})
  end

  # First non-nil of two optional strings (keeps the `||` off the hot path).
  def self._or(primary : String?, fallback : String?) : String?
    primary || fallback
  end

  # Validate a maintenance outcome request.
  def self._validate_maintenance(event_type : String, artifact_id : String, artifact_type : String, evidence_revision_id : String?, superseding_version : String?) : Nil
    raise Chronicle::Packs::PackError.new("maintenance outcome must be contradicted, stale, or superseded") if !Events::MAINTENANCE.includes?(event_type)
    raise Chronicle::Packs::PackError.new("maintenance outcome requires an artifact subject") if artifact_id.empty? || artifact_type.empty?
    raise Chronicle::Packs::PackError.new("contradicted/stale outcomes require evidence_revision_id") if event_type.in?({"outcome.contradicted", "outcome.stale"}) && evidence_revision_id.nil?
    raise Chronicle::Packs::PackError.new("superseded outcome requires superseding_version") if event_type == "outcome.superseded" && superseding_version.nil?
  end

  def self._find_usage(reader : Chronicle::GraphProjection, usage_id : String) : Chronicle::GraphObject?
    _objects(reader, "skill_usage").find { |obj| JSON.parse(obj.data)["usage_id"]?.try(&.as_s?) == usage_id }
  end

  # Resolve the usage and its id from an evaluation's data/metadata.
  def self._resolve_trace_usage(read_view : Chronicle::GraphProjection, data : Hash(String, JSON::Any), usage_id : String?) : {Chronicle::GraphObject?, String?}
    metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    resolved_usage_id = usage_id || metadata["usage_id"]?.try(&.as_s?)
    usage = resolved_usage_id ? _find_usage(read_view, resolved_usage_id) : nil
    if usage.nil? && (data["subject_type"]?.try(&.as_s?)) == "skill_usage"
      candidate = _get_object(read_view, data["subject_id"]?.try(&.as_s?) || "")
      if candidate && candidate.type == "skill_usage"
        usage = candidate
        resolved_usage_id = JSON.parse(candidate.data)["usage_id"]?.try(&.as_s?)
      end
    end
    {usage, resolved_usage_id}
  end

  # Resolve the artifact identity from an evaluation's data/metadata/usage.
  def self._resolve_trace_artifact(
    data : Hash(String, JSON::Any),
    usage : Chronicle::GraphObject?,
    artifact_id : String?,
    artifact_type : String?,
    artifact_version : String?,
  ) : NamedTuple(artifact_id: String, artifact_type: String, artifact_version: String?)
    metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    resolved_artifact_id = _or(artifact_id, metadata["artifact_id"]?.try(&.as_s?))
    resolved_artifact_type = _or(artifact_type, metadata["artifact_type"]?.try(&.as_s?))
    resolved_artifact_version = _or(artifact_version, metadata["artifact_version"]?.try(&.as_s?))
    if usage
      usage_data = JSON.parse(usage.data).as_h
      resolved_artifact_id = _or(resolved_artifact_id, usage_data["skill_version_id"]?.try(&.as_s?))
      resolved_artifact_type = _or(resolved_artifact_type, "skill_version")
      resolved_artifact_version = _or(resolved_artifact_version, usage_data["skill_version"]?.try(&.as_s?))
    end
    resolved_artifact_id = _or(resolved_artifact_id, data["subject_id"]?.try(&.as_s?)) || ""
    resolved_artifact_type = _or(resolved_artifact_type, data["subject_type"]?.try(&.as_s?)) || ""
    if resolved_artifact_id.empty? || resolved_artifact_type.empty?
      raise Chronicle::Packs::PackError.new("outcome requires an evaluation/usage/artifact subject trace")
    end
    {artifact_id: resolved_artifact_id, artifact_type: resolved_artifact_type, artifact_version: resolved_artifact_version}
  end

  # Resolve the usage/artifact subject trace from an evaluation.
  def self._subject_trace(
    read_view : Chronicle::GraphProjection,
    evaluation : Chronicle::GraphObject,
    usage_id : String?,
    artifact_id : String?,
    artifact_type : String?,
    artifact_version : String?,
  ) : NamedTuple(usage_id: String?, artifact_id: String, artifact_type: String, artifact_version: String?)
    data = JSON.parse(evaluation.data).as_h
    usage, resolved_usage_id = _resolve_trace_usage(read_view, data, usage_id)
    artifact = _resolve_trace_artifact(data, usage, artifact_id, artifact_type, artifact_version)
    {usage_id: resolved_usage_id, artifact_id: artifact[:artifact_id], artifact_type: artifact[:artifact_type], artifact_version: artifact[:artifact_version]}
  end

  # The existing terminal outcome record for an evaluation, if any.
  def self._terminal_record(reader : Chronicle::GraphProjection, evaluation_id : String) : Chronicle::GraphObject?
    _objects(reader, "outcome_record").find do |record|
      record_data = JSON.parse(record.data)
      record_data["evaluation_id"]?.try(&.as_s?) == evaluation_id &&
        Events::TERMINAL.includes?("outcome.#{record_data["outcome_type"]?.try(&.as_s?)}")
    end
  end

  # Record exactly one terminal value for an evaluation.
  def self.record_terminal_outcome_fn(
    graph : Chronicle::GraphProjection,
    event_type : String,
    evaluation_id : String,
    rationale : String,
    actor : String,
    *,
    usage_id : String? = nil,
    artifact_id : String? = nil,
    artifact_type : String? = nil,
    artifact_version : String? = nil,
    source_context : Hash(String, JSON::Any) = {} of String => JSON::Any,
    is_fixture : Bool = false,
    reader : Chronicle::GraphProjection? = nil,
  ) : Hash(String, JSON::Any)
    event_type = "outcome.#{event_type}" if !event_type.starts_with?("outcome.")
    raise Chronicle::Packs::PackError.new("terminal outcome must be helped, hurt, or neutral") if !Events::TERMINAL.includes?(event_type)

    read_view = reader || graph
    evaluation = _get_object(read_view, evaluation_id) || _get_object(graph, evaluation_id)
    raise Chronicle::Packs::PackError.new("evaluation_id must reference a Core evaluation") if evaluation.nil? || evaluation.type != "evaluation"

    existing = _terminal_record(read_view, evaluation_id)
    if existing
      existing_type = "outcome.#{JSON.parse(existing.data)["outcome_type"]?.try(&.as_s?)}"
      raise Chronicle::Packs::PackError.new("evaluation already has a terminal outcome; correction requires supersession") if existing_type != event_type
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "record" => _object_json(existing), "evaluation" => _object_json(evaluation)}
    end

    trace = _subject_trace(read_view, evaluation, usage_id, artifact_id, artifact_type, artifact_version)
    payload = {
      "evaluation_id"     => JSON::Any.new(evaluation_id),
      "usage_id"          => JSON::Any.new(trace[:usage_id]),
      "artifact_id"       => JSON::Any.new(trace[:artifact_id]),
      "artifact_type"     => JSON::Any.new(trace[:artifact_type]),
      "artifact_version"  => JSON::Any.new(trace[:artifact_version]),
      "rationale"         => JSON::Any.new(rationale),
      "actor"             => JSON::Any.new(actor),
      "source_context"    => JSON::Any.new(source_context),
      "source_surface_id" => source_context["source_surface_id"]? || JSON::Any.new(nil),
      "source_category"   => source_context["source_category"]? || JSON::Any.new(nil),
      "contribution_key"  => JSON::Any.new("terminal:#{evaluation_id}"),
      "is_fixture"        => JSON::Any.new(is_fixture),
    }
    outcome = _emit_event(graph, event_type, payload, actor)
    record = graph.add_object("outcome_record", OutcomeRecord.new(
      outcome_event_id: outcome.id,
      outcome_type: event_type.sub("outcome.", ""),
      artifact_id: trace[:artifact_id],
      artifact_type: trace[:artifact_type],
      contribution_key: "terminal:#{evaluation_id}",
      actor: actor,
      evaluation_id: evaluation_id,
      usage_id: trace[:usage_id],
      artifact_version: trace[:artifact_version],
      rationale: rationale,
      source_context: source_context,
      is_fixture: is_fixture,
    ).to_json)
    begin
      graph.add_relation(record.id, evaluation_id, "records_evaluation")
    rescue
    end
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "record" => _object_json(record), "evaluation" => _object_json(evaluation)}
  end

  # Create an evaluation for an explicit verdict when none is supplied.
  def self._create_verdict_evaluation(
    graph : Chronicle::GraphProjection,
    verdict : String,
    rationale : String,
    actor : String,
    usage_id : String?,
    artifact_id : String?,
    artifact_type : String?,
    artifact_version : String?,
  ) : {Chronicle::GraphObject, String?, String?, String?, Bool}
    mapping = {
      "accept"  => {"outcome.helped", "accepted"},
      "reject"  => {"outcome.hurt", "rejected"},
      "neutral" => {"outcome.neutral", "completed_neutrally"},
    }
    _, judgment = mapping[verdict]

    resolved_artifact_id = artifact_id
    resolved_artifact_type = artifact_type
    resolved_artifact_version = artifact_version
    resolved_fixture = false

    usage = usage_id ? _find_usage(graph, usage_id) : nil
    subject_id = ""
    subject_type = ""
    if usage
      usage_data = JSON.parse(usage.data).as_h
      subject_id = usage.id
      subject_type = "skill_usage"
      resolved_artifact_id = _or(resolved_artifact_id, usage_data["skill_version_id"]?.try(&.as_s?))
      resolved_artifact_type = _or(resolved_artifact_type, "skill_version")
      resolved_artifact_version = _or(resolved_artifact_version, usage_data["skill_version"]?.try(&.as_s?))
      resolved_fixture = resolved_fixture || (usage_data["is_fixture"]?.try(&.as_bool?) || false)
    elsif resolved_artifact_id && resolved_artifact_type
      subject_id = resolved_artifact_id
      subject_type = resolved_artifact_type
    else
      raise Chronicle::Packs::PackError.new("explicit verdict requires evaluation_id, usage_id, or artifact subject")
    end

    evaluation = graph.add_object("evaluation", JSON.build do |json|
      json.object do
        json.field "subject_id", subject_id
        json.field "subject_type", subject_type
        json.field "judgment", judgment
        json.field "rationale", rationale
        json.field "evaluator", actor
        json.field "metadata", {
          "usage_id"         => JSON::Any.new(usage_id),
          "artifact_id"      => JSON::Any.new(resolved_artifact_id),
          "artifact_type"    => JSON::Any.new(resolved_artifact_type),
          "artifact_version" => JSON::Any.new(resolved_artifact_version),
          "capture_outcome"  => JSON::Any.new(true),
        }
      end
    end)
    {evaluation, resolved_artifact_id, resolved_artifact_type, resolved_artifact_version, resolved_fixture}
  end

  # Capture an explicit accept/reject/neutral verdict with no model judgment.
  def self.record_explicit_verdict_fn(
    graph : Chronicle::GraphProjection,
    verdict : String,
    rationale : String,
    actor : String,
    *,
    evaluation_id : String? = nil,
    usage_id : String? = nil,
    artifact_id : String? = nil,
    artifact_type : String? = nil,
    artifact_version : String? = nil,
    source_context : Hash(String, JSON::Any) = {} of String => JSON::Any,
    is_fixture : Bool = false,
  ) : Hash(String, JSON::Any)
    mapping = {
      "accept"  => {"outcome.helped", "accepted"},
      "reject"  => {"outcome.hurt", "rejected"},
      "neutral" => {"outcome.neutral", "completed_neutrally"},
    }
    entry = mapping[verdict]?
    raise Chronicle::Packs::PackError.new("verdict must be accept, reject, or neutral") if entry.nil?

    event_type, _ = entry
    resolved_artifact_id = artifact_id
    resolved_artifact_type = artifact_type
    resolved_artifact_version = artifact_version
    resolved_fixture = is_fixture

    if evaluation_id.nil?
      created, resolved_artifact_id, resolved_artifact_type, resolved_artifact_version, resolved_fixture =
        _create_verdict_evaluation(graph, verdict, rationale, actor, usage_id, artifact_id, artifact_type, artifact_version)
      evaluation_id = created.id
    end

    result = record_terminal_outcome_fn(
      graph, event_type, evaluation_id, rationale, actor,
      usage_id: usage_id, artifact_id: resolved_artifact_id, artifact_type: resolved_artifact_type,
      artifact_version: resolved_artifact_version, source_context: source_context, is_fixture: resolved_fixture,
    )
    result["evaluation_id"] = JSON::Any.new(evaluation_id)
    result
  end

  # Record one idempotent contradicted, stale, or superseded outcome.
  def self.record_maintenance_outcome_fn(
    graph : Chronicle::GraphProjection,
    event_type : String,
    artifact_id : String,
    artifact_type : String,
    rationale : String,
    actor : String,
    *,
    artifact_version : String? = nil,
    evidence_revision_id : String? = nil,
    superseding_version : String? = nil,
    evaluation_id : String? = nil,
    usage_id : String? = nil,
    source_context : Hash(String, JSON::Any) = {} of String => JSON::Any,
    is_fixture : Bool = false,
    reader : Chronicle::GraphProjection? = nil,
  ) : Hash(String, JSON::Any)
    event_type = "outcome.#{event_type}" if !event_type.starts_with?("outcome.")
    _validate_maintenance(event_type, artifact_id, artifact_type, evidence_revision_id, superseding_version)

    subject_key = evidence_revision_id || superseding_version
    contribution_key = "#{artifact_id}:#{subject_key}:#{event_type}"

    read_view = reader || graph
    existing = _objects(read_view, "outcome_record").find { |obj| JSON.parse(obj.data)["contribution_key"]?.try(&.as_s?) == contribution_key }
    if existing
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "record" => _object_json(existing)}
    end

    if evaluation_id
      evaluation = _get_object(read_view, evaluation_id) || _get_object(graph, evaluation_id)
      raise Chronicle::Packs::PackError.new("evaluation_id must reference a Core evaluation") if evaluation.nil? || evaluation.type != "evaluation"
    end

    payload = {
      "evaluation_id"        => JSON::Any.new(evaluation_id),
      "usage_id"             => JSON::Any.new(usage_id),
      "artifact_id"          => JSON::Any.new(artifact_id),
      "artifact_type"        => JSON::Any.new(artifact_type),
      "artifact_version"     => JSON::Any.new(artifact_version),
      "evidence_revision_id" => JSON::Any.new(evidence_revision_id),
      "superseding_version"  => JSON::Any.new(superseding_version),
      "rationale"            => JSON::Any.new(rationale),
      "actor"                => JSON::Any.new(actor),
      "source_context"       => JSON::Any.new(source_context),
      "contribution_key"     => JSON::Any.new(contribution_key),
      "is_fixture"           => JSON::Any.new(is_fixture),
    }
    outcome = _emit_event(graph, event_type, payload, actor)
    record = graph.add_object("outcome_record", OutcomeRecord.new(
      outcome_event_id: outcome.id,
      outcome_type: event_type.sub("outcome.", ""),
      artifact_id: artifact_id,
      artifact_type: artifact_type,
      contribution_key: contribution_key,
      actor: actor,
      evaluation_id: evaluation_id,
      usage_id: usage_id,
      artifact_version: artifact_version,
      evidence_revision_id: evidence_revision_id,
      superseding_version: superseding_version,
      rationale: rationale,
      source_context: source_context,
      is_fixture: is_fixture,
    ).to_json)
    if evaluation_id
      begin
        graph.add_relation(record.id, evaluation_id, "records_evaluation")
      rescue
      end
    end
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "record" => _object_json(record)}
  end

  # Correct an evaluation through replacement plus outcome.superseded.
  def self.supersede_evaluation_fn(
    graph : Chronicle::GraphProjection,
    prior_evaluation_id : String,
    replacement_verdict : String,
    rationale : String,
    actor : String,
  ) : Hash(String, JSON::Any)
    prior = graph.get_object(prior_evaluation_id)
    raise Chronicle::Packs::PackError.new("prior_evaluation_id must reference a Core evaluation") if prior.nil? || prior.type != "evaluation"

    prior_terminal = _terminal_record(graph, prior_evaluation_id)
    raise Chronicle::Packs::PackError.new("the prior evaluation has no terminal outcome to supersede") if prior_terminal.nil?

    mapping = {
      "accept"  => {"outcome.helped", "accepted"},
      "reject"  => {"outcome.hurt", "rejected"},
      "neutral" => {"outcome.neutral", "completed_neutrally"},
    }
    entry = mapping[replacement_verdict]?
    raise Chronicle::Packs::PackError.new("replacement_verdict must be accept, reject, or neutral") if entry.nil?

    replacement_event_type, judgment = entry
    pdata = JSON.parse(prior_terminal.data).as_h

    replacement = graph.add_object("evaluation", JSON.build do |json|
      json.object do
        json.field "subject_id", prior_evaluation_id
        json.field "subject_type", "evaluation"
        json.field "judgment", judgment
        json.field "rationale", rationale
        json.field "evaluator", actor
        json.field "metadata", {
          "supersedes_evaluation_id" => JSON::Any.new(prior_evaluation_id),
          "artifact_id"              => pdata["artifact_id"],
          "artifact_type"            => pdata["artifact_type"],
          "artifact_version"         => pdata["artifact_version"]?,
        }
      end
    end)

    superseded = record_maintenance_outcome_fn(
      graph, "outcome.superseded", pdata["artifact_id"].as_s, pdata["artifact_type"].as_s,
      rationale, actor,
      artifact_version: pdata["artifact_version"]?.try(&.as_s?),
      superseding_version: replacement.id,
      evaluation_id: prior_evaluation_id,
      usage_id: pdata["usage_id"]?.try(&.as_s?),
      is_fixture: pdata["is_fixture"]?.try(&.as_bool?) || false,
    )
    terminal = record_terminal_outcome_fn(
      graph, replacement_event_type, replacement.id, rationale, actor,
      artifact_id: pdata["artifact_id"].as_s,
      artifact_type: pdata["artifact_type"].as_s,
      artifact_version: pdata["artifact_version"]?.try(&.as_s?),
      is_fixture: pdata["is_fixture"]?.try(&.as_bool?) || false,
    )

    {
      "ok"                     => JSON::Any.new(true),
      "replacement_evaluation" => _object_json(replacement),
      "supersession"           => superseded["record"],
      "terminal"               => terminal["record"],
    }
  end

  # The current artifact-owned reliability projection, or nil.
  def self.get_reliability_fn(graph : Chronicle::GraphProjection, artifact_id : String) : Hash(String, JSON::Any)?
    reliability = _objects(graph, "artifact_reliability").reverse.find { |obj| JSON.parse(obj.data)["artifact_id"]?.try(&.as_s?) == artifact_id }
    return nil if reliability.nil?

    {"object_id" => JSON::Any.new(reliability.id)}.merge(JSON.parse(reliability.data).as_h)
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "record_explicit_verdict", description: "Record an explicit accept, reject, or neutral outcome.", deterministic: true)]
  def record_explicit_verdict_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_explicit_verdict_fn(
      bound_graph_or_raise,
      input["verdict"]?.try(&.as_s?) || "",
      input["rationale"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "owner",
      evaluation_id: input["evaluation_id"]?.try(&.as_s?),
      usage_id: input["usage_id"]?.try(&.as_s?),
      artifact_id: input["artifact_id"]?.try(&.as_s?),
      artifact_type: input["artifact_type"]?.try(&.as_s?),
      artifact_version: input["artifact_version"]?.try(&.as_s?),
      source_context: input["source_context"]?.try(&.as_h) || {} of String => JSON::Any,
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_maintenance_outcome", description: "Record contradicted, stale, or superseded artifact evidence.", deterministic: true)]
  def record_maintenance_outcome_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_maintenance_outcome_fn(
      bound_graph_or_raise,
      input["event_type"]?.try(&.as_s?) || "",
      input["artifact_id"]?.try(&.as_s?) || "",
      input["artifact_type"]?.try(&.as_s?) || "",
      input["rationale"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "owner",
      artifact_version: input["artifact_version"]?.try(&.as_s?),
      evidence_revision_id: input["evidence_revision_id"]?.try(&.as_s?),
      superseding_version: input["superseding_version"]?.try(&.as_s?),
      evaluation_id: input["evaluation_id"]?.try(&.as_s?),
      usage_id: input["usage_id"]?.try(&.as_s?),
      source_context: input["source_context"]?.try(&.as_h) || {} of String => JSON::Any,
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "supersede_evaluation", description: "Correct a terminal evaluation through explicit supersession.", deterministic: true)]
  def supersede_evaluation_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = supersede_evaluation_fn(
      bound_graph_or_raise,
      input["prior_evaluation_id"]?.try(&.as_s?) || "",
      input["replacement_verdict"]?.try(&.as_s?) || "neutral",
      input["rationale"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "owner",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_artifact_reliability", description: "Read the current artifact-owned reliability projection.", deterministic: true)]
  def get_artifact_reliability_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = get_reliability_fn(bound_graph_or_raise, input["artifact_id"]?.try(&.as_s?) || "")
    result ? result.to_json : "null"
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "eval_outcome tools require a bound graph (set EvalOutcome.bound_graph)"
    )
  end
end

require "json"
require "digest/sha256"

module Chronicle::Packs::Skills
  # Skills mutation/query capabilities. Ported from upstream
  # packs/skills/tools.py. The `*_fn` functions take the graph explicitly;
  # the declared Chronicle::Tool wrappers read a graph bound by the host.

  class_property bound_graph : Chronicle::GraphProjection? = nil
  class_property event_seq : UInt64 = 0

  def self._stable_id(prefix : String, *parts : String) : String
    material = parts.join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  # Compact JSON with sorted keys (byte-for-byte canonical form).
  def self._canonical_json(value : JSON::Any) : String
    _sort_json(value).to_json
  end

  def self._sort_json(value : JSON::Any) : JSON::Any
    case raw = value.raw
    when Hash(String, JSON::Any)
      JSON::Any.new(raw.keys.sort!.to_h { |key| {key, _sort_json(raw[key])} })
    when Array(JSON::Any)
      JSON::Any.new(raw.map { |item| _sort_json(item) })
    else
      value
    end
  end

  # Emit a custom event through the graph (so the runtime can dispatch on it).
  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any)) : Chronicle::Event
    seq = (self.event_seq += 1)
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{event_type.gsub('.', '_')}_#{seq}",
      type: event_type, actor: "skills", caused_by: nil,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
  end

  def self._objects(reader : Chronicle::GraphProjection, object_type : String) : Array(Chronicle::GraphObject)
    reader.objects(type: object_type)
  end

  def self._find_skill(reader : Chronicle::GraphProjection, name : String, version : String) : Chronicle::GraphObject?
    _objects(reader, "skill").find { |obj| JSON.parse(obj.data)["name"]?.try(&.as_s?) == name && JSON.parse(obj.data)["version"]?.try(&.as_s?) == version }
  end

  def self._find_skill_by_object_or_identity(reader : Chronicle::GraphProjection, artifact_id : String) : Chronicle::GraphObject?
    if obj = reader.get_object(artifact_id)
      return obj if obj.type == "skill"
    end
    _objects(reader, "skill").find { |candidate| JSON.parse(candidate.data)["version_identity"]?.try(&.as_s?) == artifact_id }
  end

  def self._object_json(obj : Chronicle::GraphObject) : JSON::Any
    JSON::Any.new({"id" => JSON::Any.new(obj.id), "type" => JSON::Any.new(obj.type), "data" => JSON.parse(obj.data)})
  end

  # Read a skill's promotion history as typed entries.
  def self._read_history(skill_data : Hash(String, JSON::Any)) : Array(PromotionHistoryEntry)
    (skill_data["promotion_history"]?.try(&.as_a?) || [] of JSON::Any).map { |item| PromotionHistoryEntry.from_json(item.to_json) }
  end

  def self._clean_list(items : Array(String)) : Array(JSON::Any)
    items.map(&.strip).select { |value| !value.empty? }.sort!.map { |value| JSON::Any.new(value) }
  end

  def self._definition(
    name : String,
    version : String,
    description : String,
    trigger_conditions : Array(String),
    required_capabilities : Array(String),
    contraindications : Array(String),
  ) : Hash(String, JSON::Any)
    {
      "name"                  => JSON::Any.new(name.strip),
      "version"               => JSON::Any.new(version.strip),
      "description"           => JSON::Any.new(description.strip),
      "trigger_conditions"    => JSON::Any.new(_clean_list(trigger_conditions)),
      "required_capabilities" => JSON::Any.new(_clean_list(required_capabilities)),
      "contraindications"     => JSON::Any.new(_clean_list(contraindications)),
    }
  end

  # Build the canonical definition and evidence refs, raising on invalid input.
  def self._validated_definition(
    name : String,
    version : String,
    description : String,
    trigger_conditions : Array(String),
    required_capabilities : Array(String),
    contraindications : Array(String),
    source_evidence_refs : Array(String),
  ) : {Hash(String, JSON::Any), Array(String)}
    definition = _definition(name, version, description, trigger_conditions, required_capabilities, contraindications)
    raise Chronicle::Packs::PackError.new("skill name is required") if definition["name"].as_s.empty?
    evidence_refs = source_evidence_refs.map(&.strip).select { |value| !value.empty? }.sort!
    raise Chronicle::Packs::PackError.new("skill proposal requires source evidence provenance") if evidence_refs.empty?
    {definition, evidence_refs}
  end

  # Validate that every capability request is declared and has a provider.
  def self._validate_capability_requests(graph : Chronicle::GraphProjection, requests : Array(Hash(String, JSON::Any)), required : Array(String)) : Nil
    requests.each do |request|
      key = request["capability_key"]?.try(&.as_s?) || ""
      raise Chronicle::Packs::PackError.new("capability request #{key.inspect} is not declared by the skill") if !required.includes?(key)
      provider = graph.get_object(request["provider_id"]?.try(&.as_s?) || "")
      raise Chronicle::Packs::PackError.new("capability request #{key.inspect} has no valid provider") if provider.nil? || provider.type != "capability_provider"
    end
  end

  # Create the proposed capability_call objects for an invocation.
  def self._create_capability_calls(
    graph : Chronicle::GraphProjection,
    requests : Array(Hash(String, JSON::Any)),
    skill_data : Hash(String, JSON::Any),
    usage_id : String,
    source_context : Hash(String, JSON::Any),
    skill_version_id : String,
  ) : Array(Chronicle::GraphObject)
    calls = [] of Chronicle::GraphObject
    requests.each do |request|
      provider_id = request["provider_id"].as_s
      key = request["capability_key"].as_s
      provider_name, _, capability_name = key.partition('.')
      calls << graph.add_object("capability_call", JSON.build do |json|
        json.object do
          json.field "provider_id", provider_id
          json.field "provider_name", provider_name
          json.field "capability_name", capability_name.empty? ? key : capability_name
          json.field "input_data", request["input_data"]?.try(&.as_h) || {} of String => JSON::Any
          json.field "credential_ref_name", request["credential_ref_name"]?
          json.field "credential_ref_id", request["credential_ref_id"]?
          json.field "risk_class", request["risk_class"]?.try(&.as_s?) || "medium"
          json.field "status", "proposed"
          json.field "proposed_by", "skills:#{skill_data["version_identity"].as_s}"
          json.field "frame_id", source_context["frame_id"]?
          json.field "metadata", {"skill_usage_id" => JSON::Any.new(usage_id), "skill_version_id" => JSON::Any.new(skill_version_id)}
        end
      end)
    end
    calls
  end

  # Author one immutable definition version with mandatory provenance.
  def self.author_skill_fn(
    graph : Chronicle::GraphProjection,
    name : String,
    version : String,
    description : String = "",
    trigger_conditions : Array(String) = [] of String,
    required_capabilities : Array(String) = [] of String,
    contraindications : Array(String) = [] of String,
    source_evidence_refs : Array(String) = [] of String,
    source_candidate_id : String? = nil,
    actor : String = "owner",
    is_fixture : Bool = false,
    metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    *,
    reader : Chronicle::GraphProjection? = nil,
  ) : Hash(String, JSON::Any)
    read_view = reader || graph
    definition, evidence_refs = _validated_definition(name, version, description, trigger_conditions, required_capabilities, contraindications, source_evidence_refs)

    skill_id = _stable_id("skill", definition["name"].as_s.downcase)
    version_identity = _stable_id("skill_version", skill_id, definition["version"].as_s)
    definition_hash = Digest::SHA256.hexdigest(_canonical_json(JSON::Any.new(definition)))

    existing = _find_skill(read_view, definition["name"].as_s, definition["version"].as_s)
    if existing
      if JSON.parse(existing.data)["definition_hash"]?.try(&.as_s?) != definition_hash
        raise Chronicle::Packs::PackError.new("skill version identity already exists with a different definition; author a materially new semantic version")
      end
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "skill" => _object_json(existing)}
    end

    proposed = _emit_event(graph, "skill.proposed", {
      "artifact_id"          => JSON::Any.new(version_identity),
      "skill_id"             => JSON::Any.new(skill_id),
      "skill_version"        => definition["version"],
      "name"                 => definition["name"],
      "source_evidence_refs" => JSON::Any.new(evidence_refs.map { |ref| JSON::Any.new(ref) }),
      "source_candidate_id"  => JSON::Any.new(source_candidate_id),
      "actor"                => JSON::Any.new(actor),
      "is_fixture"           => JSON::Any.new(is_fixture),
    })

    merged_metadata = metadata.merge({
      "proposed_event_id" => JSON::Any.new(proposed.id),
      "proposed_by"       => JSON::Any.new(actor),
    })
    skill = graph.add_object("skill", SkillArtifact.new(
      skill_id: skill_id,
      version_identity: version_identity,
      name: definition["name"].as_s,
      version: definition["version"].as_s,
      definition_hash: definition_hash,
      description: definition["description"].as_s,
      trigger_conditions: _clean_list(trigger_conditions).map(&.as_s),
      required_capabilities: _clean_list(required_capabilities).map(&.as_s),
      contraindications: _clean_list(contraindications).map(&.as_s),
      source_evidence_refs: evidence_refs,
      source_candidate_id: source_candidate_id,
      is_fixture: is_fixture,
      metadata: merged_metadata,
    ).to_json)

    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "skill" => _object_json(skill)}
  end

  # Create the skill_usage object and usage_of relation for an invocation.
  def self._record_usage(
    graph : Chronicle::GraphProjection,
    skill : Chronicle::GraphObject,
    skill_data : Hash(String, JSON::Any),
    usage_id : String,
    execution_ref : String,
    execution_kind : String,
    actor : String,
    source_context : Hash(String, JSON::Any),
    required : Array(String),
    is_fixture : Bool,
  ) : Chronicle::GraphObject
    used = _emit_event(graph, "skill.used", {
      "usage_id"              => JSON::Any.new(usage_id),
      "skill_id"              => skill_data["skill_id"],
      "skill_version"         => skill_data["version"],
      "skill_version_id"      => JSON::Any.new(skill.id),
      "execution_ref"         => JSON::Any.new(execution_ref),
      "execution_kind"        => JSON::Any.new(execution_kind),
      "actor"                 => JSON::Any.new(actor),
      "source_context"        => JSON::Any.new(source_context),
      "required_capabilities" => JSON::Any.new(required.map { |item| JSON::Any.new(item) }),
      "is_fixture"            => JSON::Any.new(is_fixture),
    })
    usage = graph.add_object("skill_usage", SkillUsage.new(
      usage_id: usage_id, skill_id: skill_data["skill_id"].as_s,
      skill_version: skill_data["version"].as_s, skill_version_id: skill.id,
      execution_ref: execution_ref, execution_kind: execution_kind, actor: actor,
      source_context: source_context, required_capabilities: required,
      used_event_id: used.id, is_fixture: is_fixture,
    ).to_json)
    graph.add_relation(usage.id, skill.id, "usage_of")
    usage
  end

  # Validate that an invocation is permitted for this skill state.
  def self._assert_invocable(skill_data : Hash(String, JSON::Any), execution_kind : String, allow_candidate_trials : Bool) : Nil
    status = skill_data["status"]?.try(&.as_s?) || "candidate"
    raise Chronicle::Packs::PackError.new("skill version is not eligible: #{status}") if status.in?({"demoted", "disabled"})
    raise Chronicle::Packs::PackError.new("real invocation requires a promoted skill version") if execution_kind == "real" && status != "promoted"
    raise Chronicle::Packs::PackError.new("candidate trial invocation is disabled") if execution_kind == "trial" && status == "candidate" && !allow_candidate_trials
  end

  # Return the existing usage for a usage_id (idempotency), or nil.
  def self._existing_usage(graph : Chronicle::GraphProjection, usage_id : String, execution_ref : String, skill : Chronicle::GraphObject) : Hash(String, JSON::Any)?
    existing = _objects(graph, "skill_usage").find { |obj| JSON.parse(obj.data)["usage_id"]?.try(&.as_s?) == usage_id }
    return nil if existing.nil?

    same = JSON.parse(existing.data)["skill_version_id"]?.try(&.as_s?) == skill.id &&
           JSON.parse(existing.data)["execution_ref"]?.try(&.as_s?) == execution_ref
    raise Chronicle::Packs::PackError.new("usage_id already belongs to a different execution or skill version") if !same
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "usage" => _object_json(existing), "capability_calls" => JSON::Any.new([] of JSON::Any)}
  end

  # Invoke one exact version once; retries return the original usage.
  def self.invoke_skill_fn(
    graph : Chronicle::GraphProjection,
    name : String,
    version : String,
    usage_id : String,
    execution_ref : String,
    execution_kind : String = "trial",
    actor : String = "agent",
    source_context : Hash(String, JSON::Any) = {} of String => JSON::Any,
    capability_requests : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
    is_fixture : Bool = false,
    allow_candidate_trials : Bool = true,
  ) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("execution_kind must be 'real' or 'trial'") if !execution_kind.in?({"real", "trial"})
    if usage_id.strip.empty? || execution_ref.strip.empty? || actor.strip.empty?
      raise Chronicle::Packs::PackError.new("usage_id, execution_ref, and actor are required")
    end

    skill = _find_skill(graph, name, version)
    raise Chronicle::Packs::PackError.new("unknown skill version #{name.inspect}@#{version}") if skill.nil?

    if existing_result = _existing_usage(graph, usage_id, execution_ref, skill)
      return existing_result
    end

    skill_data = JSON.parse(skill.data).as_h
    _assert_invocable(skill_data, execution_kind, allow_candidate_trials)

    required = skill_data["required_capabilities"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    _validate_capability_requests(graph, capability_requests, required)

    usage = _record_usage(graph, skill, skill_data, usage_id, execution_ref, execution_kind, actor, source_context, required, is_fixture)

    capability_calls = _create_capability_calls(graph, capability_requests, skill_data, usage_id, source_context, skill.id)
    if !capability_calls.empty?
      merged = JSON.parse(usage.data).as_h
      merged["capability_call_ids"] = JSON::Any.new(capability_calls.map { |call| JSON::Any.new(call.id) })
      graph.patch_object(usage.id, merged.to_json)
      if patched = graph.get_object(usage.id)
        usage = patched
      end
    end
    if !(skill_data["definition_locked"]?.try(&.as_bool?) || false)
      skill_locked = JSON.parse(skill.data).as_h
      skill_locked["definition_locked"] = JSON::Any.new(true)
      graph.patch_object(skill.id, skill_locked.to_json)
    end

    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "usage" => _object_json(usage), "capability_calls" => JSON::Any.new(capability_calls.map { |call| _object_json(call) })}
  end

  # Record evidence without changing eligibility.
  def self.record_promotion_evidence_fn(
    graph : Chronicle::GraphProjection,
    skill_version_id : String,
    kind : String,
    reference_ids : Array(String),
    rationale : String = "",
    actor : String = "",
    accepted : Bool = true,
    metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
  ) : Hash(String, JSON::Any)
    skill = _find_skill_by_object_or_identity(graph, skill_version_id)
    raise Chronicle::Packs::PackError.new("unknown skill version") if skill.nil?

    refs = reference_ids.map(&.strip).select { |value| !value.empty? }.sort!
    raise Chronicle::Packs::PackError.new("promotion evidence requires reference ids") if refs.empty?
    if kind == "repeated_accepted_use" && refs.size < 2
      raise Chronicle::Packs::PackError.new("repeated accepted use requires at least two distinct references")
    end
    if kind == "owner_approval" && (actor.strip.empty? || rationale.strip.empty?)
      raise Chronicle::Packs::PackError.new("owner approval requires actor and recorded rationale")
    end

    evidence_id = _stable_id("skill_evidence", skill.id, kind, _canonical_json(JSON::Any.new(refs.map { |ref| JSON::Any.new(ref) })))
    existing = _objects(graph, "skill_promotion_evidence").find { |obj| JSON.parse(obj.data)["evidence_id"]?.try(&.as_s?) == evidence_id }
    if existing
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "evidence" => _object_json(existing)}
    end

    evidence = graph.add_object("skill_promotion_evidence", SkillPromotionEvidence.new(
      evidence_id: evidence_id, skill_version_id: skill.id, kind: kind,
      reference_ids: refs, accepted: accepted, rationale: rationale, actor: actor, metadata: metadata,
    ).to_json)
    graph.add_relation(evidence.id, skill.id, "promotion_for")
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "evidence" => _object_json(evidence)}
  end

  def self._promotion_support(graph : Chronicle::GraphProjection, skill : Chronicle::GraphObject, evidence : Chronicle::GraphObject) : {Bool, String}
    skill_id = skill.id
    version_identity = JSON.parse(skill.data)["version_identity"]?.try(&.as_s?)
    reliability = _objects(graph, "artifact_reliability").select do |obj|
      artifact_id = JSON.parse(obj.data)["artifact_id"]?.try(&.as_s?)
      artifact_id == skill_id || artifact_id == version_identity
    end
    if !reliability.empty?
      verdict = JSON.parse(reliability.last.data)["verdict"]?.try(&.as_s?) || "weak"
      return {verdict == "supported", "artifact reliability is #{verdict}"}
    end
    if JSON.parse(evidence.data)["accepted"]?.try(&.as_bool?) || false
      return {true, "accepted #{JSON.parse(evidence.data)["kind"]?.try(&.as_s?) || "evidence"} evidence"}
    end
    {false, "recorded evidence was not accepted"}
  end

  # Promote only from accepted proof and a supporting reliability state.
  def self.promote_skill_fn(
    graph : Chronicle::GraphProjection,
    skill_version_id : String,
    evidence_id : String,
    rationale : String,
    actor : String = "owner",
  ) : Hash(String, JSON::Any)
    skill = _find_skill_by_object_or_identity(graph, skill_version_id)
    raise Chronicle::Packs::PackError.new("unknown skill version") if skill.nil?

    evidence = _objects(graph, "skill_promotion_evidence").find do |obj|
      data = JSON.parse(obj.data)
      data["evidence_id"]?.try(&.as_s?) == evidence_id && data["skill_version_id"]?.try(&.as_s?) == skill.id
    end
    raise Chronicle::Packs::PackError.new("promotion requires recorded evidence for this exact version") if evidence.nil?

    supported, support_reason = _promotion_support(graph, skill, evidence)
    raise Chronicle::Packs::PackError.new("promotion reliability gate failed: #{support_reason}") if !supported

    skill_data = JSON.parse(skill.data).as_h
    status = skill_data["status"]?.try(&.as_s?) || "candidate"
    evidence_kind = JSON.parse(evidence.data)["kind"]?.try(&.as_s?) || ""
    if status == "disabled" && evidence_kind != "owner_approval"
      raise Chronicle::Packs::PackError.new("disabled skill restoration requires explicit owner approval")
    end
    if status == "promoted"
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "skill" => _object_json(skill)}
    end

    prior = status
    _emit_event(graph, "skill.promoted", {
      "artifact_id"       => JSON::Any.new(skill.id),
      "skill_id"          => skill_data["skill_id"],
      "skill_version"     => skill_data["version"],
      "evidence_id"       => JSON::Any.new(evidence_id),
      "rationale"         => JSON::Any.new(rationale),
      "actor"             => JSON::Any.new(actor),
      "prior_status"      => JSON::Any.new(prior),
      "reliability_basis" => JSON::Any.new(support_reason),
      "is_fixture"        => skill_data["is_fixture"]? || JSON::Any.new(false),
    })
    history = _read_history(skill_data)
    history << PromotionHistoryEntry.new(evidence_id: evidence_id, rationale: rationale, actor: actor, prior_status: prior, new_status: "promoted")
    merged = skill_data
    merged["status"] = JSON::Any.new("promoted")
    merged["demotion_reason"] = JSON::Any.new(nil)
    merged["promotion_history"] = JSON.parse(history.to_json)
    graph.patch_object(skill.id, merged.to_json)
    updated = graph.get_object(skill.id)
    if updated
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "skill" => _object_json(updated)}
    end
    {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "skill" => _object_json(skill)}
  end

  def self._set_ineligible(
    graph : Chronicle::GraphProjection,
    skill_version_id : String,
    status : String,
    reason : String,
    actor : String,
    evidence_event_id : String?,
  ) : Hash(String, JSON::Any)
    skill = _find_skill_by_object_or_identity(graph, skill_version_id)
    raise Chronicle::Packs::PackError.new("unknown skill version") if skill.nil?
    raise Chronicle::Packs::PackError.new("invalid ineligible status") if !status.in?({"demoted", "disabled"})

    skill_data = JSON.parse(skill.data).as_h
    if (skill_data["status"]?.try(&.as_s?) || "candidate") == status
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "skill" => _object_json(skill)}
    end

    _emit_event(graph, "skill.#{status}", {
      "artifact_id"               => JSON::Any.new(skill.id),
      "skill_id"                  => skill_data["skill_id"],
      "skill_version"             => skill_data["version"],
      "reason"                    => JSON::Any.new(reason),
      "actor"                     => JSON::Any.new(actor),
      "outcome_evidence_event_id" => JSON::Any.new(evidence_event_id),
      "is_fixture"                => skill_data["is_fixture"]? || JSON::Any.new(false),
    })
    metadata = skill_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    metadata["demoted_by_reliability"] = JSON::Any.new(!evidence_event_id.nil? && status == "demoted")
    merged = skill_data
    merged["status"] = JSON::Any.new(status)
    merged["demotion_reason"] = JSON::Any.new(reason)
    merged["metadata"] = JSON::Any.new(metadata)
    graph.patch_object(skill.id, merged.to_json)
    updated = graph.get_object(skill.id)
    if updated
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "skill" => _object_json(updated)}
    end
    {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "skill" => _object_json(skill)}
  end

  def self.demote_skill_fn(
    graph : Chronicle::GraphProjection,
    skill_version_id : String,
    reason : String,
    actor : String = "owner",
    evidence_event_id : String? = nil,
  ) : Hash(String, JSON::Any)
    _set_ineligible(graph, skill_version_id, "demoted", reason, actor, evidence_event_id)
  end

  def self.disable_skill_fn(
    graph : Chronicle::GraphProjection,
    skill_version_id : String,
    reason : String,
    actor : String = "owner",
    evidence_event_id : String? = nil,
  ) : Hash(String, JSON::Any)
    _set_ineligible(graph, skill_version_id, "disabled", reason, actor, evidence_event_id)
  end

  # Link at most one Core evaluation to a usage and emit skill.evaluated.
  def self.link_skill_evaluation_fn(
    graph : Chronicle::GraphProjection,
    usage_id : String,
    evaluation_id : String,
    *,
    reader : Chronicle::GraphProjection? = nil,
  ) : Hash(String, JSON::Any)
    read_view = reader || graph
    usage = _objects(read_view, "skill_usage").find { |obj| JSON.parse(obj.data)["usage_id"]?.try(&.as_s?) == usage_id }
    raise Chronicle::Packs::PackError.new("unknown skill usage") if usage.nil?
    evaluation = graph.get_object(evaluation_id)
    raise Chronicle::Packs::PackError.new("evaluation_id must reference a Core evaluation") if evaluation.nil? || evaluation.type != "evaluation"

    existing = _objects(read_view, "skill_evaluation_link").find { |obj| JSON.parse(obj.data)["usage_id"]?.try(&.as_s?) == usage_id }
    if existing
      raise Chronicle::Packs::PackError.new("usage_id has already been evaluated") if JSON.parse(existing.data)["evaluation_id"]?.try(&.as_s?) != evaluation_id
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "link" => _object_json(existing)}
    end

    usage_data = JSON.parse(usage.data)
    evaluated = _emit_event(graph, "skill.evaluated", {
      "usage_id"         => JSON::Any.new(usage_id),
      "evaluation_id"    => JSON::Any.new(evaluation_id),
      "skill_id"         => usage_data["skill_id"],
      "skill_version"    => usage_data["skill_version"],
      "skill_version_id" => usage_data["skill_version_id"],
      "is_fixture"       => usage_data["is_fixture"]? || JSON::Any.new(false),
    })
    link = graph.add_object("skill_evaluation_link", SkillEvaluationLink.new(
      usage_id: usage_id, skill_version_id: usage_data["skill_version_id"].as_s,
      evaluation_id: evaluation_id, evaluated_event_id: evaluated.id,
    ).to_json)
    graph.add_relation(link.id, usage.id, "evaluation_of_usage")
    graph.add_relation(link.id, evaluation_id, "links_evaluation")
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "link" => _object_json(link)}
  end

  def self.list_eligible_skills_fn(graph : Chronicle::GraphProjection) : Array(Hash(String, JSON::Any))
    _objects(graph, "skill").select { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "promoted" }.map do |obj|
      {"object_id" => JSON::Any.new(obj.id)}.merge(JSON.parse(obj.data).as_h)
    end
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "author_skill", description: "Author an immutable skill version with provenance.", deterministic: true)]
  def author_skill_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = author_skill_fn(
      bound_graph_or_raise,
      input["name"]?.try(&.as_s?) || "",
      input["version"]?.try(&.as_s?) || "0.1.0",
      input["description"]?.try(&.as_s?) || "",
      input["trigger_conditions"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      input["required_capabilities"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      input["contraindications"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      input["source_evidence_refs"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      input["source_candidate_id"]?.try(&.as_s?),
      input["actor"]?.try(&.as_s?) || "owner",
      input["is_fixture"]?.try(&.as_bool?) || false,
      input["metadata"]?.try(&.as_h) || {} of String => JSON::Any,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "invoke_skill", description: "Invoke one exact eligible skill version idempotently.", deterministic: true)]
  def invoke_skill_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = invoke_skill_fn(
      bound_graph_or_raise,
      input["name"]?.try(&.as_s?) || "",
      input["version"]?.try(&.as_s?) || "0.1.0",
      input["usage_id"]?.try(&.as_s?) || "",
      input["execution_ref"]?.try(&.as_s?) || "",
      input["execution_kind"]?.try(&.as_s?) || "trial",
      input["actor"]?.try(&.as_s?) || "agent",
      input["source_context"]?.try(&.as_h) || {} of String => JSON::Any,
      input["capability_requests"]?.try(&.as_a?.try(&.map(&.as_h))) || [] of Hash(String, JSON::Any),
      input["is_fixture"]?.try(&.as_bool?) || false,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_skill_promotion_evidence", description: "Record proof for one exact skill version.", deterministic: true)]
  def record_skill_promotion_evidence_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_promotion_evidence_fn(
      bound_graph_or_raise,
      input["skill_version_id"]?.try(&.as_s?) || "",
      input["kind"]?.try(&.as_s?) || "verification",
      input["reference_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      input["rationale"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "",
      input["accepted"]?.try(&.as_bool?) != false,
      input["metadata"]?.try(&.as_h) || {} of String => JSON::Any,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "promote_skill", description: "Promote a skill version from recorded evidence and reliability.", deterministic: true)]
  def promote_skill_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = promote_skill_fn(
      bound_graph_or_raise,
      input["skill_version_id"]?.try(&.as_s?) || "",
      input["evidence_id"]?.try(&.as_s?) || "",
      input["rationale"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "owner",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "demote_skill", description: "Make a skill version ineligible without erasing history.", deterministic: true)]
  def demote_skill_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = demote_skill_fn(
      bound_graph_or_raise,
      input["skill_version_id"]?.try(&.as_s?) || "",
      input["reason"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "owner",
      input["evidence_event_id"]?.try(&.as_s?),
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "disable_skill", description: "Disable a skill version without erasing history.", deterministic: true)]
  def disable_skill_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = disable_skill_fn(
      bound_graph_or_raise,
      input["skill_version_id"]?.try(&.as_s?) || "",
      input["reason"]?.try(&.as_s?) || "",
      input["actor"]?.try(&.as_s?) || "owner",
      input["evidence_event_id"]?.try(&.as_s?),
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "skills tools require a bound graph (set Skills.bound_graph)"
    )
  end
end

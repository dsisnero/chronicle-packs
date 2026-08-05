require "json"
require "digest/sha256"

module Chronicle::Packs::Attention
  # Attention tools. Ported from upstream packs/attention/tools.py. The
  # `*_fn` functions take the graph explicitly; the declared Chronicle::Tool
  # wrappers read a graph bound by the host (chronicle's Tool model is
  # args-only).

  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._object_by_field(graph : Chronicle::GraphProjection, object_type : String, field : String, value : String) : Chronicle::GraphObject?
    graph.objects(type: object_type).find { |obj| JSON.parse(obj.data)[field]?.try(&.as_s?) == value }
  end

  def self._observation_payload(
    item : Hash(String, JSON::Any),
    session_id : String?,
    default_source : String,
  ) : AttentionObservation
    opportunity_id = _take(item, "opportunity_id").try(&.as_s?)
    signal_type = _as_s(item["signal_type"]?)
    if signal_type == "nonresponse_window" && opportunity_id.nil?
      raise Chronicle::Packs::PackError.new("nonresponse_window requires opportunity_id")
    end

    metadata = {} of String => JSON::Any
    if m = _take(item, "metadata").try(&.as_h)
      m.each { |key, value| metadata[key] = value }
    end
    item.each { |key, value| metadata[key] = value }

    AttentionObservation.new(
      observation_id: _as_s(_take(item, "observation_id")),
      subject_ref: _as_s(_take(item, "subject_ref")),
      signal_type: AttentionSignalType.parse?(signal_type) || AttentionSignalType::Opened,
      subject_kind: _as_s(_take(item, "subject_kind"), "object"),
      strength_milli: _take(item, "strength_milli").try(&.as_i?) || 1_000,
      context_key: _as_s(_take(item, "context_key"), "global"),
      objective_ref: _take(item, "objective_ref").try(&.as_s?),
      horizon_key: _as_s(_take(item, "horizon_key"), "current"),
      session_id: session_id || _take(item, "session_id").try(&.as_s?),
      opportunity_id: opportunity_id,
      active_ms: _take(item, "active_ms").try(&.as_i?),
      occurred_at: _take(item, "occurred_at").try(&.as_s?),
      source: AttentionSource.parse?(_as_s(_take(item, "source"), default_source)) || AttentionSource::Client,
      explicit: _take(item, "explicit").try(&.as_bool?) || false,
      evidence_refs: _take(item, "evidence_refs").try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      metadata: metadata,
    )
  end

  def self._object_json(obj : Chronicle::GraphObject) : JSON::Any
    JSON::Any.new({"id" => JSON::Any.new(obj.id), "type" => JSON::Any.new(obj.type), "data" => JSON.parse(obj.data)})
  end

  # Record one idempotent semantic observation. Absence is censored unless
  # the caller proves an opportunity.
  def self.record_attention_observation_fn(
    graph : Chronicle::GraphProjection,
    *,
    observation_id : String,
    subject_ref : String,
    signal_type : String,
    subject_kind : String = "object",
    strength_milli : Int32 = 1_000,
    context_key : String = "global",
    objective_ref : String? = nil,
    horizon_key : String = "current",
    session_id : String? = nil,
    opportunity_id : String? = nil,
    active_ms : Int32? = nil,
    occurred_at : String? = nil,
    source : String = "client",
    explicit : Bool = false,
    evidence_refs : Array(String) = [] of String,
    metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
  ) : Hash(String, JSON::Any)
    if signal_type == "nonresponse_window" && opportunity_id.nil?
      raise Chronicle::Packs::PackError.new("nonresponse_window requires opportunity_id")
    end

    observation = AttentionObservation.new(
      observation_id: observation_id, subject_ref: subject_ref, signal_type: AttentionSignalType.parse?(signal_type) || AttentionSignalType::Opened,
      subject_kind: subject_kind, strength_milli: strength_milli, context_key: context_key,
      objective_ref: objective_ref, horizon_key: horizon_key, session_id: session_id,
      opportunity_id: opportunity_id, active_ms: active_ms, occurred_at: occurred_at,
      source: AttentionSource.parse?(source) || AttentionSource::Client, explicit: explicit, evidence_refs: evidence_refs, metadata: metadata,
    )

    if existing = _object_by_field(graph, "attention_observation", "observation_id", observation_id)
      if JSON.parse(existing.data).as_h != JSON.parse(observation.to_json).as_h
        raise Chronicle::Packs::PackError.new("observation_id #{observation_id.inspect} already has different data")
      end
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "observation" => _object_json(existing)}
    end

    obj = graph.add_object("attention_observation", observation.to_json)
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "observation" => _object_json(obj)}
  end

  # Flush a semantic-only batch atomically with respect to validation.
  def self.record_interaction_batch_fn(
    graph : Chronicle::GraphProjection,
    *,
    batch_id : String,
    session_id : String,
    batch_sequence : Int32,
    client_id : String,
    observations : Array(Hash(String, JSON::Any)),
    client_version : String = "",
    started_at : String? = nil,
    ended_at : String? = nil,
    active_duration_ms : Int32 = 0,
    raw_event_count : Int32 = 0,
    flush_reason : String = "manual",
    metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    settings : AttentionSettings? = nil,
  ) : Hash(String, JSON::Any)
    settings = settings || AttentionSettings.from_json("{}")
    if observations.size > settings.max_observations_per_batch
      raise Chronicle::Packs::PackError.new("interaction batch exceeds #{settings.max_observations_per_batch} observations")
    end

    if existing = _object_by_field(graph, "interaction_batch", "batch_id", batch_id)
      data = JSON.parse(existing.data)
      [{"session_id", session_id}, {"batch_sequence", batch_sequence.to_s}, {"client_id", client_id}].each do |field, expected|
        if data[field]?.try(&.as_s?) != expected
          raise Chronicle::Packs::PackError.new("batch_id #{batch_id.inspect} already belongs to a different #{field}")
        end
      end
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "batch" => _object_json(existing), "observations" => JSON::Any.new([] of JSON::Any)}
    end

    prepared = [] of AttentionObservation
    observations.each_with_index do |row, index|
      item = row.dup
      observation_id = _as_s(item["observation_id"]?) || _stable_key("attention_observation", session_id, batch_sequence.to_s, index.to_s)
      item["observation_id"] = JSON::Any.new(observation_id)
      prepared << _observation_payload(item, session_id, "client")
    end

    created = [] of JSON::Any
    prepared.each do |observation|
      next unless _object_by_field(graph, "attention_observation", "observation_id", observation.observation_id).nil?

      created << _object_json(graph.add_object("attention_observation", observation.to_json))
    end

    batch = graph.add_object("interaction_batch", InteractionBatch.new(
      batch_id: batch_id, session_id: session_id, batch_sequence: batch_sequence, client_id: client_id,
      client_version: client_version, started_at: started_at, ended_at: ended_at,
      active_duration_ms: active_duration_ms,
      observation_ids: prepared.map(&.observation_id),
      raw_event_count: raw_event_count, flush_reason: flush_reason, metadata: metadata,
    ).to_json)

    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "batch" => _object_json(batch), "observations" => JSON::Any.new(created)}
  end

  # Explain current learned importance for one subject.
  def self.get_importance_fn(
    graph : Chronicle::GraphProjection,
    subject_ref : String,
    *,
    context_key : String = "global",
    objective_ref : String? = nil,
    horizon_key : String = "current",
  ) : Hash(String, JSON::Any)
    vectors = graph.objects(type: "importance_vector")
    row = vectors.find do |vector|
      data = JSON.parse(vector.data)
      data["subject_ref"]?.try(&.as_s?) == subject_ref &&
        data["context_key"]?.try(&.as_s?) == context_key &&
        (data["objective_ref"]?.try(&.as_s?) || nil) == objective_ref &&
        data["horizon_key"]?.try(&.as_s?) == horizon_key
    end
    if row.nil?
      return {
        "subject_ref"      => JSON::Any.new(subject_ref),
        "context_key"      => JSON::Any.new(context_key),
        "objective_ref"    => JSON::Any.new(objective_ref),
        "horizon_key"      => JSON::Any.new(horizon_key),
        "score_milli"      => JSON::Any.new(500),
        "confidence_milli" => JSON::Any.new(0),
        "priority_band"    => JSON::Any.new("unranked"),
        "features"         => JSON::Any.new({} of String => JSON::Any),
        "evidence_refs"    => JSON::Any.new([] of JSON::Any),
        "policy_id"        => JSON::Any.new(Policy::POLICY_ID),
        "policy_version"   => JSON::Any.new(Policy::POLICY_VERSION),
      }
    end
    data = JSON.parse(row.data).as_h
    data["object_id"] = JSON::Any.new(row.id)
    data["evidence_refs"] = JSON::Any.new(data["observation_ids"]?.try(&.as_a?) || [] of JSON::Any)
    data
  end

  # Explain learned source trust in one domain.
  def self.get_source_trust_fn(
    graph : Chronicle::GraphProjection,
    source_ref : String,
    *,
    domain : String = "general",
    query_scope : String = "general",
  ) : Hash(String, JSON::Any)
    row = graph.objects(type: "source_trust_vector").find do |vector|
      data = JSON.parse(vector.data)
      data["source_ref"]?.try(&.as_s?) == source_ref &&
        data["domain"]?.try(&.as_s?) == domain &&
        data["query_scope"]?.try(&.as_s?) == query_scope
    end
    if row.nil?
      return {
        "source_ref"       => JSON::Any.new(source_ref),
        "domain"           => JSON::Any.new(domain),
        "query_scope"      => JSON::Any.new(query_scope),
        "score_milli"      => JSON::Any.new(500),
        "confidence_milli" => JSON::Any.new(0),
        "verdict"          => JSON::Any.new("unproven"),
        "features"         => JSON::Any.new({} of String => JSON::Any),
        "evidence_refs"    => JSON::Any.new([] of JSON::Any),
        "policy_id"        => JSON::Any.new(Policy::POLICY_ID),
        "policy_version"   => JSON::Any.new(Policy::POLICY_VERSION),
      }
    end
    data = JSON.parse(row.data).as_h
    data["object_id"] = JSON::Any.new(row.id)
    data["evidence_refs"] = JSON::Any.new(data["outcome_event_ids"]?.try(&.as_a?) || [] of JSON::Any)
    data
  end

  # Rank subjects with an explicit deterministic exploration reserve.
  def self.rank_importance_fn(
    graph : Chronicle::GraphProjection,
    subject_refs : Array(String),
    *,
    context_key : String = "global",
    objective_ref : String? = nil,
    horizon_key : String = "current",
    limit : Int32 = 10,
    exploration_slots : Int32 = 1,
  ) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("limit must be positive") if limit < 1
    raise Chronicle::Packs::PackError.new("exploration_slots must be between zero and limit") if exploration_slots < 0 || exploration_slots > limit

    refs = [] of String
    subject_refs.each do |ref|
      refs << ref if !ref.empty? && !refs.includes?(ref)
    end

    rows = refs.map do |ref|
      get_importance_fn(graph, ref, context_key: context_key, objective_ref: objective_ref, horizon_key: horizon_key)
    end
    ranked = rows.select { |row| row["priority_band"].as_s != "unranked" }
    unranked = rows.select { |row| row["priority_band"].as_s == "unranked" }

    ranked.sort! do |a, b|
      score_cmp = b["score_milli"].as_i <=> a["score_milli"].as_i
      if score_cmp != 0
        score_cmp
      else
        confidence_cmp = b["confidence_milli"].as_i <=> a["confidence_milli"].as_i
        if confidence_cmp != 0
          confidence_cmp
        else
          a["subject_ref"].as_s <=> b["subject_ref"].as_s
        end
      end
    end
    unranked.sort! do |a, b|
      hash_a = Digest::SHA256.hexdigest("#{context_key}\x1f#{objective_ref || ""}\x1f#{a["subject_ref"].as_s}")
      hash_b = Digest::SHA256.hexdigest("#{context_key}\x1f#{objective_ref || ""}\x1f#{b["subject_ref"].as_s}")
      hash_a <=> hash_b
    end

    explore = unranked.first(exploration_slots)
    exploit_limit = Math.max(0, limit - explore.size)
    selected = [] of Hash(String, JSON::Any)
    ranked.first(exploit_limit).each do |row|
      selected << row.merge({"selection_reason" => JSON::Any.new("importance")})
    end
    explore.each do |row|
      selected << row.merge({"selection_reason" => JSON::Any.new("exploration")})
    end

    {
      "items"             => JSON::Any.new(selected.map { |row| JSON::Any.new(row) }),
      "considered"        => JSON::Any.new(rows.size),
      "exploration_slots" => JSON::Any.new(exploration_slots),
      "policy_id"         => JSON::Any.new(Policy::POLICY_ID),
      "policy_version"    => JSON::Any.new(Policy::POLICY_VERSION),
    }
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "record_attention_observation", description: "Record one semantic attention signal.", deterministic: true)]
  def record_attention_observation_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_attention_observation_fn(
      bound_graph_or_raise,
      observation_id: input["observation_id"]?.try(&.as_s?) || "",
      subject_ref: input["subject_ref"]?.try(&.as_s?) || "",
      signal_type: input["signal_type"]?.try(&.as_s?) || "opened",
      subject_kind: input["subject_kind"]?.try(&.as_s?) || "object",
      strength_milli: input["strength_milli"]?.try(&.as_i?) || 1_000,
      context_key: input["context_key"]?.try(&.as_s?) || "global",
      objective_ref: input["objective_ref"]?.try(&.as_s?),
      horizon_key: input["horizon_key"]?.try(&.as_s?) || "current",
      session_id: input["session_id"]?.try(&.as_s?),
      opportunity_id: input["opportunity_id"]?.try(&.as_s?),
      active_ms: input["active_ms"]?.try(&.as_i?),
      occurred_at: input["occurred_at"]?.try(&.as_s?),
      source: input["source"]?.try(&.as_s?) || "client",
      explicit: input["explicit"]?.try(&.as_bool?) || false,
      evidence_refs: input["evidence_refs"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      metadata: input["metadata"]?.try(&.as_h) || {} of String => JSON::Any,
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "record_interaction_batch", description: "Flush a bounded semantic-only client session batch.", deterministic: true)]
  def record_interaction_batch_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = record_interaction_batch_fn(
      bound_graph_or_raise,
      batch_id: input["batch_id"]?.try(&.as_s?) || "",
      session_id: input["session_id"]?.try(&.as_s?) || "",
      batch_sequence: input["batch_sequence"]?.try(&.as_i?) || 0,
      client_id: input["client_id"]?.try(&.as_s?) || "client",
      observations: input["observations"]?.try(&.as_a?.try(&.map(&.as_h))) || [] of Hash(String, JSON::Any),
      client_version: input["client_version"]?.try(&.as_s?) || "",
      active_duration_ms: input["active_duration_ms"]?.try(&.as_i?) || 0,
      raw_event_count: input["raw_event_count"]?.try(&.as_i?) || 0,
      flush_reason: input["flush_reason"]?.try(&.as_s?) || "manual",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_importance", description: "Explain current learned importance for one subject.", deterministic: true)]
  def get_importance_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = get_importance_fn(
      bound_graph_or_raise,
      input["subject_ref"]?.try(&.as_s?) || "",
      context_key: input["context_key"]?.try(&.as_s?) || "global",
      objective_ref: input["objective_ref"]?.try(&.as_s?),
      horizon_key: input["horizon_key"]?.try(&.as_s?) || "current",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "get_source_trust", description: "Explain learned source trust in one domain.", deterministic: true)]
  def get_source_trust_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = get_source_trust_fn(
      bound_graph_or_raise,
      input["source_ref"]?.try(&.as_s?) || "",
      domain: input["domain"]?.try(&.as_s?) || "general",
      query_scope: input["query_scope"]?.try(&.as_s?) || "general",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "rank_importance", description: "Rank subjects with explicit exploration reserve.", deterministic: true)]
  def rank_importance_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = rank_importance_fn(
      bound_graph_or_raise,
      input["subject_refs"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      context_key: input["context_key"]?.try(&.as_s?) || "global",
      objective_ref: input["objective_ref"]?.try(&.as_s?),
      horizon_key: input["horizon_key"]?.try(&.as_s?) || "current",
      limit: input["limit"]?.try(&.as_i?) || 10,
      exploration_slots: input["exploration_slots"]?.try(&.as_i?) || 1,
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "attention tools require a bound graph (set Attention.bound_graph)"
    )
  end
end

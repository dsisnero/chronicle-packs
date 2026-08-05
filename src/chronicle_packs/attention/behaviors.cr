require "json"
require "digest/sha256"

module Chronicle::Packs::Attention
  # Attention behaviors. Ported from upstream packs/attention/behaviors.py.
  #
  # semantic_attention_signal_capture validates neutral family/domain signals
  # into owned observations; the projectors learn inspectable importance and
  # source-trust vectors from those observations and canonical outcomes.

  # Projection policy constants and weights. Nested module so the DSL's
  # `pack` macro (which assumes every direct constant is a type) doesn't
  # trip over the map/string constants.
  module Policy
    POLICY_ID      = "importance-trust.beta-evidence"
    POLICY_VERSION = 1

    # Engagement is evidence of salience, not truth. Weights are
    # deliberately conservative and versioned.
    IMPORTANCE_WEIGHTS = {
      "impression"             => {"opportunity", 0},
      "opened"                 => {"engagement", 120},
      "active_dwell"           => {"engagement", 300},
      "revisited"              => {"recurrence", 220},
      "created"                => {"outcome", 350},
      "edited"                 => {"outcome", 400},
      "replied"                => {"outcome", 650},
      "completed"              => {"outcome", 700},
      "dismissed"              => {"negative", -700},
      "archived"               => {"negative", -250},
      "explicit_important"     => {"explicit", 1_000},
      "explicit_not_important" => {"explicit", -1_000},
      "nonresponse_window"     => {"negative", -180},
      "llm_judgment"           => {"model_only", 0},
    }

    OUTCOME_WEIGHTS = {
      "outcome.helped"       => {"helped", 1_000},
      "outcome.hurt"         => {"hurt", -1_000},
      "outcome.contradicted" => {"contradicted", -1_000},
      "outcome.stale"        => {"stale", -600},
      "outcome.neutral"      => {"neutral", 0},
      "outcome.superseded"   => {"superseded", 0},
    }
  end

  def self._stable_key(prefix : String, *parts : String) : String
    material = parts.join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  # Importance score from support/oppose evidence: (score, confidence, band).
  def self.importance_score(support : Int32, oppose : Int32) : {Int32, Int32, String}
    effective = support + oppose
    score = ((1_000 + support) * 1_000) // (2_000 + effective)
    confidence = Math.min(1_000, (effective * 1_000) // 4_000)
    band = if effective == 0
             "unranked"
           elsif score >= 650
             "high"
           elsif score <= 350
             "low"
           else
             "medium"
           end
    {score, confidence, band}
  end

  # Source-trust score from support/challenge: (score, confidence, verdict).
  def self.trust_score(support : Int32, challenge : Int32) : {Int32, Int32, String}
    effective = support + challenge
    score = ((1_000 + support) * 1_000) // (2_000 + effective)
    confidence = Math.min(1_000, (effective * 1_000) // 3_000)
    verdict = if effective == 0
                "unproven"
              elsif score >= 650
                "supported"
              elsif score <= 350
                "harmful"
              else
                "weak"
              end
    {score, confidence, verdict}
  end

  def self._as_s(value : JSON::Any?, default : String = "") : String
    value.try(&.as_s?) || default
  end

  def self._as_i(value : JSON::Any?, default : Int32) : Int32
    value.try(&.as_i?) || default
  end

  def self._as_bool(value : JSON::Any?, default : Bool) : Bool
    value.try(&.as_bool?) || default
  end

  def self._as_h(value : JSON::Any?) : Hash(String, JSON::Any)
    value.try(&.as_h) || {} of String => JSON::Any
  end

  def self._as_str_list(value : JSON::Any?) : Array(String)
    value.try(&.as_a?.try(&.map(&.as_s))) || [] of String
  end

  # Pop a key from a row hash, returning nil when absent (Hash#delete
  # raises on a missing key).
  def self._take(item : Hash(String, JSON::Any), key : String) : JSON::Any?
    value = item[key]?
    item.delete(key) if value
    value
  end

  # The sources implicated by an outcome payload (source_context).
  def self._trust_sources(payload : JSON::Any) : Array(Hash(String, JSON::Any))
    context = payload["source_context"]?.try(&.as_h) || {} of String => JSON::Any
    if rows = context["trust_sources"]?.try(&.as_a?)
      result = [] of Hash(String, JSON::Any)
      rows.each do |row|
        if row.raw.is_a?(Hash) && row.as_h["source_ref"]?
          result << row.as_h
        end
      end
      return result
    end

    source_ref = context["source_ref"]?.try(&.as_s?) || context["source_surface_id"]?.try(&.as_s?)
    return [] of Hash(String, JSON::Any) if source_ref.nil?

    [{
      "source_ref"  => JSON::Any.new(source_ref),
      "source_kind" => JSON::Any.new(context["source_kind"]?.try(&.as_s?) || "source"),
      "domain"      => JSON::Any.new(context["domain"]?.try(&.as_s?) || context["source_category"]?.try(&.as_s?) || "general"),
      "query_scope" => JSON::Any.new(context["query_scope"]?.try(&.as_s?) || "general"),
    }]
  end

  # Build an AttentionObservation from a signal row, or nil for a malformed
  # row. Absence is censored unless an opportunity is proven.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream signal row builder
  def self._signal_observation(row : JSON::Any, producer : String) : AttentionObservation?
    return nil unless row.raw.is_a?(Hash)

    item = row.as_h.dup
    observation_id = _as_s(_take(item, "observation_id"))
    subject_ref = _as_s(_take(item, "subject_ref"))
    signal_type = _as_s(_take(item, "signal_type"))
    return nil if observation_id.empty? || subject_ref.empty? || signal_type.empty?

    opportunity_id = _take(item, "opportunity_id").try(&.as_s?)
    if signal_type == "nonresponse_window" && opportunity_id.nil?
      raise Chronicle::Packs::PackError.new("nonresponse_window requires opportunity_id")
    end

    metadata = {"producer" => JSON::Any.new(producer)}
    if m = _take(item, "metadata").try(&.as_h)
      m.each { |key, value| metadata[key] = value }
    end
    item.each { |key, value| metadata[key] = value }

    signal_enum = AttentionSignalType.parse?(signal_type)
    if signal_enum.nil?
      raise Chronicle::Packs::PackError.new("unknown signal_type #{signal_type.inspect}")
    end
    AttentionObservation.new(
      observation_id: observation_id,
      subject_ref: subject_ref,
      signal_type: signal_enum,
      subject_kind: _as_s(_take(item, "subject_kind"), "object"),
      strength_milli: _take(item, "strength_milli").try(&.as_i?) || 1_000,
      context_key: _as_s(_take(item, "context_key"), "global"),
      objective_ref: _take(item, "objective_ref").try(&.as_s?),
      horizon_key: _as_s(_take(item, "horizon_key"), "current"),
      session_id: _take(item, "session_id").try(&.as_s?),
      opportunity_id: opportunity_id,
      active_ms: _take(item, "active_ms").try(&.as_i?),
      occurred_at: _take(item, "occurred_at").try(&.as_s?),
      source: AttentionSource.parse?(_as_s(_take(item, "source"), "connector")) || AttentionSource::Connector,
      explicit: _take(item, "explicit").try(&.as_bool?) || false,
      evidence_refs: _take(item, "evidence_refs").try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      metadata: metadata,
    )
  end

  # Validate neutral family/domain signals into owned observations.
  @[Chronicle::Packs::Annotations::Behavior(name: "semantic_attention_signal_capture", on: ["attention.signal_observed"], creates: ["attention_observation"])]
  def semantic_attention_signal_capture(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    payload = JSON.parse(event.payload)
    producer = _as_s(payload["producer"]?, event.actor)
    observations = payload["observations"]?.try(&.as_a?) || [] of JSON::Any

    observations.each do |row|
      observation = _signal_observation(row, producer)
      next if observation.nil?

      if existing = graph.objects(type: "attention_observation").find { |obj| JSON.parse(obj.data)["observation_id"]?.try(&.as_s?) == observation.observation_id }
        if JSON.parse(existing.data).as_h != JSON.parse(observation.to_json).as_h
          raise Chronicle::Packs::PackError.new("attention signal observation identity collision")
        end
        next
      end

      graph.add_object("attention_observation", observation.to_json)
    end
  end

  # Project an importance vector from attention observations.
  @[Chronicle::Packs::Annotations::Behavior(name: "importance_vector_projector", on: ["object.created"], where: {"type" => "attention_observation"}, creates: ["importance_vector"])]
  def importance_vector_projector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    payload = JSON.parse(event.payload)
    data = payload["data"]?
    return if data.nil?

    observation_id = data["observation_id"]?.try(&.as_s?) || payload["id"]?.try(&.as_s?) || ""
    subject_ref = data["subject_ref"]?.try(&.as_s?) || ""
    return if observation_id.empty? || subject_ref.empty?

    if result = _importance_update(graph, data, observation_id, subject_ref)
      update, existing = result
      if existing.nil?
        graph.add_object("importance_vector", update.to_json)
      else
        graph.patch_object(existing.id, update.to_json)
      end
    end
  end

  # Accumulate one observation into the subject's importance vector.
  def self._importance_update(
    graph : Chronicle::GraphProjection,
    data : JSON::Any,
    observation_id : String,
    subject_ref : String,
  ) : {ImportanceVector, Chronicle::GraphObject?}?
    context_key = _as_s(data["context_key"]?, "global")
    objective_ref = data["objective_ref"]?.try(&.as_s?)
    horizon_key = _as_s(data["horizon_key"]?, "current")
    vector_key = _stable_key("importance", subject_ref, context_key, objective_ref || "", horizon_key)

    existing = graph.objects(type: "importance_vector").find { |vector| JSON.parse(vector.data)["vector_key"]?.try(&.as_s?) == vector_key }
    observation_ids = existing ? _as_str_list(JSON.parse(existing.data)["observation_ids"]?) : [] of String
    return nil if observation_ids.includes?(observation_id)

    signal_type = _as_s(data["signal_type"]?)
    feature, weight = Policy::IMPORTANCE_WEIGHTS[signal_type]? || {"unknown", 0}
    strength = _as_i(data["strength_milli"]?, 0)
    contribution = (weight.abs * strength) // 1_000
    # Explicit signals only count when the caller marked them explicit.
    if signal_type.starts_with?("explicit_") && !_as_bool(data["explicit"]?, false)
      contribution = 0
      feature = "unverified_explicit"
    end

    prior = existing ? JSON.parse(existing.data).as_h : {} of String => JSON::Any
    support, oppose, features = _accumulate(weight, contribution, _as_i(prior["support_milli"]?, 0), _as_i(prior["oppose_milli"]?, 0), _as_h(prior["features"]?), feature)
    observation_ids << observation_id

    score, confidence, band = importance_score(support, oppose)
    band_enum = PriorityBand.parse?(band) || PriorityBand::Unranked
    update = ImportanceVector.new(
      vector_key: vector_key,
      subject_ref: subject_ref,
      subject_kind: _as_s(data["subject_kind"]?, "object"),
      context_key: context_key,
      objective_ref: objective_ref,
      horizon_key: horizon_key,
      score_milli: score,
      confidence_milli: confidence,
      priority_band: band_enum,
      support_milli: support,
      oppose_milli: oppose,
      features: features,
      observation_ids: observation_ids,
      policy_id: Policy::POLICY_ID,
      policy_version: Policy::POLICY_VERSION,
      latest_observation_id: observation_id,
      metadata: {"decay" => JSON::Any.new("none"), "llm_direct_weight" => JSON::Any.new(0)},
    )
    {update, existing}
  end

  # Apply one weighted contribution to support/oppose and the feature tally.
  def self._accumulate(
    weight : Int32,
    contribution : Int32,
    support : Int32,
    oppose : Int32,
    features : Hash(String, JSON::Any),
    feature : String,
  ) : {Int32, Int32, Hash(String, JSON::Any)}
    if weight > 0
      support += contribution
    elsif weight < 0
      oppose += contribution
    end
    features[feature] = JSON::Any.new((features[feature]?.try(&.as_i?) || 0) + contribution)
    {support, oppose, features}
  end

  # Project a source-trust vector from canonical outcome events.
  @[Chronicle::Packs::Annotations::Behavior(name: "source_trust_vector_projector", on: ["outcome.contradicted", "outcome.helped", "outcome.hurt", "outcome.neutral", "outcome.stale", "outcome.superseded"], creates: ["source_trust_vector"])]
  def source_trust_vector_projector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    payload = JSON.parse(event.payload)
    feature, weight = Policy::OUTCOME_WEIGHTS[event.type]? || {"unknown", 0}

    _trust_sources(payload).each do |source|
      source_ref = source["source_ref"].as_s
      source_kind = _as_s(source["source_kind"]?, "source")
      domain = _as_s(source["domain"]?, "general")
      query_scope = _as_s(source["query_scope"]?, "general")
      vector_key = _stable_key("source_trust", source_ref, domain, query_scope)

      existing = graph.objects(type: "source_trust_vector").find { |vector| JSON.parse(vector.data)["vector_key"]?.try(&.as_s?) == vector_key }
      event_ids = existing ? (_as_str_list(JSON.parse(existing.data)["outcome_event_ids"]?)) : [] of String
      next if event_ids.includes?(event.id)

      prior = existing ? JSON.parse(existing.data).as_h : {} of String => JSON::Any
      support = _as_i(prior["support_milli"]?, 0)
      challenge = _as_i(prior["challenge_milli"]?, 0)
      if weight > 0
        support += weight
      elsif weight < 0
        challenge += weight.abs
      end
      features = _as_h(prior["features"]?)
      features[feature] = JSON::Any.new((features[feature]?.try(&.as_i?) || 0) + weight.abs)
      event_ids << event.id

      score, confidence, verdict = trust_score(support, challenge)
      verdict_enum = AttentionVerdict.parse?(verdict) || AttentionVerdict::Unproven
      update = SourceTrustVector.new(
        vector_key: vector_key,
        source_ref: source_ref,
        source_kind: source_kind,
        domain: domain,
        query_scope: query_scope,
        score_milli: score,
        confidence_milli: confidence,
        verdict: verdict_enum,
        support_milli: support,
        challenge_milli: challenge,
        features: features,
        outcome_event_ids: event_ids,
        policy_id: Policy::POLICY_ID,
        policy_version: Policy::POLICY_VERSION,
        latest_outcome_event_id: event.id,
        metadata: {"decay" => JSON::Any.new("none"), "self_assertion" => JSON::Any.new("ignored")},
      )
      if existing.nil?
        graph.add_object("source_trust_vector", update.to_json)
      else
        graph.patch_object(existing.id, update.to_json)
      end
    end
  end
end

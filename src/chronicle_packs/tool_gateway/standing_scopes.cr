require "json"

module Chronicle::Packs::ToolGateway
  # Standing-scope tool policies — ADR 0018's automation stage. Ported from
  # upstream packs/tool_gateway/standing_scopes.py. Sustained prediction
  # accuracy → tool_policy candidate → explicit owner promotion → the
  # gateway's action-class dimension auto-approves the scope's R2 capability
  # within the runtime ceiling; accuracy degradation demotes, observably.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module StandingScopeRules
    RULES = {
      "rule_id"                       => "tool_policy.standing_scope.prediction_accuracy",
      "rule_version"                  => 1,
      "min_predictions"               => 8,
      "min_accuracy_percent"          => 90,
      "max_action_class"              => "R2",
      "demote_below_accuracy_percent" => 90,
    }
    ALLOWED_CLASSES = Set(String).new(["R0", "R1", "R2"])
    MATCHES         = {
      "approve" => Set(String).new(["approved"]),
      "reject"  => Set(String).new(["rejected", "edited"]),
    }
  end

  # Emit through raw Graph or constrained BehaviorGraph.
  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any), actor : String = "tool_gateway") : Chronicle::Event
    event = Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: graph.events.size.to_u64 + 1,
      id: "ev_#{graph.events.size + 1}",
      type: event_type,
      actor: actor,
      caused_by: nil,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
    event
  end

  def self.pair_matched(predicted_verdict : String, actual_verdict : String) : Bool
    StandingScopeRules::MATCHES[predicted_verdict]?.try(&.includes?(actual_verdict)) || false
  end

  def self.accuracy_percent(pairs : Array(Hash(String, JSON::Any))) : Int32
    return 0 if pairs.empty?

    matches = pairs.count do |pair|
      pair_matched(pair["predicted_verdict"]?.try(&.as_s?) || "", pair["actual_verdict"]?.try(&.as_s?) || "")
    end
    matches * 100 // pairs.size
  end

  def self._event_index_of_ref(graph : Chronicle::GraphProjection, ref : String) : Int32?
    graph.events.each_with_index do |event, index|
      if event.id == ref
        return index
      end
      if event.type == "object.created" && (JSON.parse(event.payload)["id"]?.try(&.as_s?) == ref)
        return index
      end
    end
    nil
  end

  # No-backfill guard: every prediction precedes its decision.
  def self._validate_pairs(graph : Chronicle::GraphProjection, pairs : Array(Hash(String, JSON::Any))) : Nil
    pairs.each do |pair|
      prediction_ref = pair["prediction_ref"]?.try(&.as_s?) || ""
      decided_ref = pair["decided_ref"]?.try(&.as_s?) || ""
      if prediction_ref.empty? || decided_ref.empty?
        raise Chronicle::Packs::PackError.new("every prediction pair needs prediction_ref and decided_ref")
      end
      prediction_index = _event_index_of_ref(graph, prediction_ref)
      decided_index = _event_index_of_ref(graph, decided_ref)
      if prediction_index.nil? || decided_index.nil?
        raise Chronicle::Packs::PackError.new("prediction pair refs must resolve to recorded events (prediction_ref=#{prediction_ref.inspect}, decided_ref=#{decided_ref.inspect}); unresolvable evidence fails closed")
      end
      if prediction_index >= decided_index
        raise Chronicle::Packs::PackError.new("prediction #{prediction_ref.inspect} does not precede its decision #{decided_ref.inspect} — backfilled predictions can never earn automation (ADR 0018)")
      end
    end
  end

  def self.find_tool_policy(graph : Chronicle::GraphProjection, scope_key : String) : Chronicle::GraphObject?
    graph.objects(type: "tool_policy").find { |obj| JSON.parse(obj.data)["scope_key"]?.try(&.as_s?) == scope_key }
  end

  # The PROMOTED standing scope covering one capability+class, or nil.
  def self.promoted_standing_scope_for(graph : Chronicle::GraphProjection, capability_key : String, action_class : String) : Hash(String, JSON::Any)?
    scope_key = "#{action_class}|#{capability_key}"
    policy = find_tool_policy(graph, scope_key)
    return nil if policy.nil?

    data = JSON.parse(policy.data).as_h
    return nil unless data["status"]?.try(&.as_s?) == "promoted"

    evidence = data["evidence"]?.try(&.as_h) || {} of String => JSON::Any
    {
      "policy_object_id" => JSON::Any.new(policy.id),
      "policy_id"        => data["policy_id"]? || JSON::Any.new(""),
      "policy_version"   => data["policy_version"]? || JSON::Any.new(1),
      "scope_key"        => JSON::Any.new(scope_key),
      "prediction_count" => evidence["prediction_count"]? || JSON::Any.new(0),
      "accuracy_percent" => evidence["accuracy_percent"]? || JSON::Any.new(0),
      "approved_by"      => data["approved_by"]? || JSON::Any.new(""),
    }
  end

  def self._patch_policy(graph : Chronicle::GraphProjection, policy_id : String, updates : Hash(String, JSON::Any)) : Nil
    current = graph.get_object(policy_id)
    return if current.nil?

    data = JSON.parse(current.data).as_h
    updates.each { |key, value| data[key] = value }
    graph.patch_object(policy_id, JSON::Any.new(data).to_json)
  end

  # Generate a standing-scope candidate from prediction history.
  def self.propose_standing_scope_fn(graph : Chronicle::GraphProjection, capability_key : String, action_class : String, prediction_pairs : Array(Hash(String, JSON::Any)), proposed_by : String, is_fixture : Bool = false) : Hash(String, JSON::Any)
    rules = StandingScopeRules::RULES
    unless StandingScopeRules::ALLOWED_CLASSES.includes?(action_class)
      raise Chronicle::Packs::PackError.new("standing scopes exist only within R0-R2; #{action_class.inspect} can never become standing regardless of accuracy (ADR 0018)")
    end
    pairs = prediction_pairs.map(&.dup)
    if pairs.size < (rules["min_predictions"].as(Int32))
      raise Chronicle::Packs::PackError.new("standing scope requires >= #{rules["min_predictions"]} resolved predictions; got #{pairs.size}")
    end
    _validate_pairs(graph, pairs)
    observed_accuracy = accuracy_percent(pairs)
    if observed_accuracy < (rules["min_accuracy_percent"].as(Int32))
      raise Chronicle::Packs::PackError.new("standing scope requires accuracy >= #{rules["min_accuracy_percent"]}%; got #{observed_accuracy}%")
    end

    scope_key = "#{action_class}|#{capability_key}"
    evidence = {
      "prediction_count" => JSON::Any.new(pairs.size),
      "accuracy_percent" => JSON::Any.new(observed_accuracy),
      "pairs"            => JSON::Any.new(pairs.map { |pair| JSON::Any.new(pair) }),
      "thresholds"       => JSON::Any.new({"rule_id" => JSON::Any.new(rules["rule_id"].as(String)), "rule_version" => JSON::Any.new(rules["rule_version"].as(Int32)), "min_predictions" => JSON::Any.new(rules["min_predictions"].as(Int32)), "min_accuracy_percent" => JSON::Any.new(rules["min_accuracy_percent"].as(Int32))}),
    }

    existing = find_tool_policy(graph, scope_key)
    if existing
      status = JSON.parse(existing.data)["status"]?.try(&.as_s?)
      if status == "candidate"
        return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "policy" => JSON::Any.new(existing.id)}
      end
      if status == "promoted"
        return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "policy" => JSON::Any.new(existing.id), "reason" => JSON::Any.new("scope is already promoted")}
      end
      next_version = (JSON.parse(existing.data)["policy_version"]?.try(&.as_i) || 1) + 1
      _emit_event(graph, "tool_policy.proposed", {
        "policy_id"        => JSON.parse(existing.data)["policy_id"]? || JSON::Any.new(""),
        "policy_version"   => JSON::Any.new(next_version),
        "scope_key"        => JSON::Any.new(scope_key),
        "capability_key"   => JSON::Any.new(capability_key),
        "action_class"     => JSON::Any.new(action_class),
        "prediction_count" => JSON::Any.new(pairs.size),
        "accuracy_percent" => JSON::Any.new(observed_accuracy),
        "rule_id"          => JSON::Any.new(rules["rule_id"].as(String)),
        "rule_version"     => JSON::Any.new(rules["rule_version"].as(Int32)),
        "proposed_by"      => JSON::Any.new(proposed_by),
        "is_fixture"       => JSON::Any.new(is_fixture),
      }, actor: "tool_gateway")
      _patch_policy(graph, existing.id, {
        "status"                 => JSON::Any.new("candidate"),
        "policy_version"         => JSON::Any.new(next_version),
        "evidence"               => JSON::Any.new(evidence),
        "proposed_by"            => JSON::Any.new(proposed_by),
        "approved_by"            => JSON::Any.new(""),
        "demotion_reason"        => JSON::Any.new(""),
        "missed_prediction_refs" => JSON::Any.new([] of JSON::Any),
        "rule_id"                => JSON::Any.new(rules["rule_id"].as(String)),
        "rule_version"           => JSON::Any.new(rules["rule_version"].as(Int32)),
      })
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "policy" => JSON::Any.new(existing.id)}
    end

    policy_id = "tool_policy_#{scope_key}"
    _emit_event(graph, "tool_policy.proposed", {
      "policy_id"        => JSON::Any.new(policy_id),
      "policy_version"   => JSON::Any.new(1),
      "scope_key"        => JSON::Any.new(scope_key),
      "capability_key"   => JSON::Any.new(capability_key),
      "action_class"     => JSON::Any.new(action_class),
      "prediction_count" => JSON::Any.new(pairs.size),
      "accuracy_percent" => JSON::Any.new(observed_accuracy),
      "rule_id"          => JSON::Any.new(rules["rule_id"].as(String)),
      "rule_version"     => JSON::Any.new(rules["rule_version"].as(Int32)),
      "proposed_by"      => JSON::Any.new(proposed_by),
      "is_fixture"       => JSON::Any.new(is_fixture),
    }, actor: "tool_gateway")
    policy = graph.add_object("tool_policy", JSON.build do |json|
      json.object do
        json.field "policy_id", policy_id
        json.field "policy_version", 1
        json.field "scope_key", scope_key
        json.field "capability_key", capability_key
        json.field "action_class", action_class
        json.field "status", "candidate"
        json.field "rule_id", rules["rule_id"].as(String)
        json.field "rule_version", rules["rule_version"].as(Int32)
        json.field "evidence", JSON::Any.new(evidence)
        json.field "proposed_by", proposed_by
        json.field "is_fixture", is_fixture
      end
    end)
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "policy" => JSON::Any.new(policy.id)}
  end

  # Promote a candidate standing scope — the owner's explicit yes.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream promotion
  def self.promote_tool_policy_fn(graph : Chronicle::GraphProjection, policy_id : String, approver_ref : String, note : String = "", approver_roles : Array(String)? = nil) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("promotion requires a non-empty approver_ref") if approver_ref.strip.empty?

    policy = graph.objects(type: "tool_policy").find { |obj| JSON.parse(obj.data)["policy_id"]?.try(&.as_s?) == policy_id }
    raise Chronicle::Packs::PackError.new("unknown tool policy #{policy_id.inspect}") if policy.nil?

    policy_data = JSON.parse(policy.data).as_h
    status = policy_data["status"]?.try(&.as_s?)
    if status == "promoted"
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "policy" => JSON::Any.new(policy.id)}
    end
    raise Chronicle::Packs::PackError.new("a disabled standing scope needs a fresh proposal") if status == "disabled"

    roles = approver_roles || ToolGatewaySettings.new.approver_roles
    verdict = _verify_approver(graph, approver_ref, roles)
    unless verdict["allowed"]?.try(&.as_bool?) || false
      raise Chronicle::Packs::PackError.new("approver refused: #{verdict["reason"]?.try(&.as_s?) || ""}")
    end

    rules = StandingScopeRules::RULES
    evidence = policy_data["evidence"]?.try(&.as_h) || {} of String => JSON::Any
    if (evidence["prediction_count"]?.try(&.as_i) || 0) < rules["min_predictions"].as(Int32) || (evidence["accuracy_percent"]?.try(&.as_i) || 0) < rules["min_accuracy_percent"].as(Int32)
      raise Chronicle::Packs::PackError.new("stored evidence no longer meets the standing-scope thresholds; re-propose from current prediction history")
    end

    event = _emit_event(graph, "tool_policy.promoted", {
      "policy_id"             => JSON::Any.new(policy_id),
      "policy_version"        => policy_data["policy_version"]? || JSON::Any.new(1),
      "scope_key"             => policy_data["scope_key"]? || JSON::Any.new(""),
      "capability_key"        => policy_data["capability_key"]? || JSON::Any.new(""),
      "action_class"          => policy_data["action_class"]? || JSON::Any.new(""),
      "prediction_count"      => evidence["prediction_count"]? || JSON::Any.new(0),
      "accuracy_percent"      => evidence["accuracy_percent"]? || JSON::Any.new(0),
      "approver"              => JSON::Any.new(approver_ref),
      "approver_verification" => verdict["verification"]? || JSON::Any.new(""),
      "note"                  => JSON::Any.new(note),
      "rule_id"               => policy_data["rule_id"]? || JSON::Any.new(""),
      "rule_version"          => policy_data["rule_version"]? || JSON::Any.new(0),
      "is_fixture"            => policy_data["is_fixture"]? || JSON::Any.new(false),
    }, actor: "tool_gateway")
    history = (policy_data["promotion_history"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h)
    history << {
      "event_id"       => JSON::Any.new(event.id),
      "policy_version" => policy_data["policy_version"]? || JSON::Any.new(1),
      "approver"       => JSON::Any.new(approver_ref),
      "prior_status"   => policy_data["status"]? || JSON::Any.new("candidate"),
      "new_status"     => JSON::Any.new("promoted"),
    }
    _patch_policy(graph, policy.id, {
      "status"                 => JSON::Any.new("promoted"),
      "approved_by"            => JSON::Any.new(approver_ref),
      "promotion_history"      => JSON::Any.new(history.map { |entry| JSON::Any.new(entry) }),
      "demotion_reason"        => JSON::Any.new(""),
      "missed_prediction_refs" => JSON::Any.new([] of JSON::Any),
    })
    {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "policy" => JSON::Any.new(policy.id), "event_id" => JSON::Any.new(event.id)}
  end

  # Demote a standing scope on accuracy degradation — reversibly.
  def self.demote_tool_policy_fn(graph : Chronicle::GraphProjection, policy_id : String, missed_prediction_refs : Array(String), observed_accuracy_percent : Int32, actor : String, reason : String = "") : Hash(String, JSON::Any)
    policy = graph.objects(type: "tool_policy").find { |obj| JSON.parse(obj.data)["policy_id"]?.try(&.as_s?) == policy_id }
    raise Chronicle::Packs::PackError.new("unknown tool policy #{policy_id.inspect}") if policy.nil?

    policy_data = JSON.parse(policy.data).as_h
    return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "reason" => JSON::Any.new("not promoted")} unless policy_data["status"]?.try(&.as_s?) == "promoted"
    raise Chronicle::Packs::PackError.new("demotion must name the missed predictions that degraded accuracy") if missed_prediction_refs.empty?

    event = _emit_event(graph, "tool_policy.demoted", {
      "policy_id"                     => JSON::Any.new(policy_id),
      "policy_version"                => policy_data["policy_version"]? || JSON::Any.new(1),
      "scope_key"                     => policy_data["scope_key"]? || JSON::Any.new(""),
      "capability_key"                => policy_data["capability_key"]? || JSON::Any.new(""),
      "action_class"                  => policy_data["action_class"]? || JSON::Any.new(""),
      "missed_prediction_refs"        => JSON::Any.new(missed_prediction_refs.map { |ref| JSON::Any.new(ref) }),
      "observed_accuracy_percent"     => JSON::Any.new(observed_accuracy_percent),
      "demote_below_accuracy_percent" => JSON::Any.new(StandingScopeRules::RULES["demote_below_accuracy_percent"].as(Int32)),
      "actor"                         => JSON::Any.new(actor),
      "reason"                        => JSON::Any.new(reason.empty? ? "accuracy fell to #{observed_accuracy_percent}% (bar: #{StandingScopeRules::RULES["demote_below_accuracy_percent"]}%)" : reason),
      "is_fixture"                    => policy_data["is_fixture"]? || JSON::Any.new(false),
    }, actor: actor)
    _patch_policy(graph, policy.id, {
      "status"                 => JSON::Any.new("demoted"),
      "demotion_reason"        => JSON::Any.new(reason.empty? ? "accuracy degraded to #{observed_accuracy_percent}%" : reason),
      "missed_prediction_refs" => JSON::Any.new(missed_prediction_refs.map { |ref| JSON::Any.new(ref) }),
    })
    {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "policy" => JSON::Any.new(policy.id), "event_id" => JSON::Any.new(event.id)}
  end

  # Disable a standing scope outright (owner veto, incident response).
  def self.disable_tool_policy_fn(graph : Chronicle::GraphProjection, policy_id : String, actor : String, reason : String) : Hash(String, JSON::Any)
    policy = graph.objects(type: "tool_policy").find { |obj| JSON.parse(obj.data)["policy_id"]?.try(&.as_s?) == policy_id }
    raise Chronicle::Packs::PackError.new("unknown tool policy #{policy_id.inspect}") if policy.nil?

    policy_data = JSON.parse(policy.data).as_h
    return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "policy" => JSON::Any.new(policy.id)} if policy_data["status"]?.try(&.as_s?) == "disabled"

    event = _emit_event(graph, "tool_policy.disabled", {
      "policy_id"      => JSON::Any.new(policy_id),
      "policy_version" => policy_data["policy_version"]? || JSON::Any.new(1),
      "scope_key"      => policy_data["scope_key"]? || JSON::Any.new(""),
      "actor"          => JSON::Any.new(actor),
      "reason"         => JSON::Any.new(reason),
      "is_fixture"     => policy_data["is_fixture"]? || JSON::Any.new(false),
    }, actor: actor)
    _patch_policy(graph, policy.id, {"status" => JSON::Any.new("disabled"), "demotion_reason" => JSON::Any.new(reason)})
    {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "policy" => JSON::Any.new(policy.id), "event_id" => JSON::Any.new(event.id)}
  end
end

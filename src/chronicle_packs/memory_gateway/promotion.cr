require "json"

module Chronicle::Packs::MemoryGateway
  # Versioned memory promotion beyond admission (P6, ADR 0018 posture).
  # Ported from upstream packs/memory_gateway/promotion.py. Admission
  # (memory_candidate -> memory_item) is storage; PROMOTION is a governed
  # lifecycle transition on an exact artifact version, earned from
  # reliability evidence and resolved only by an explicit approver. Nothing
  # promotes silently.

  # Versioned generation rule (thresholds explicit, versioned constants).
  module PromotionRules
    RULES = {
      "rule_id"             => "memory.promotion.reliability",
      "rule_version"        => 1,
      "min_helped_outcomes" => 2,
      "required_verdict"    => "supported",
      "demote_on_verdicts"  => ["harmful", "stale"],
    }
  end

  # Replay evidence cannot support a replay.verified claim (ADR 0015).
  class MemoryReplayIncompleteError < Exception
  end

  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any)) : Chronicle::Event
    event = Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: graph.events.size.to_u64 + 1,
      id: "mem_#{event_type.sub(".", "_")}_#{graph.events.size + 1}",
      type: event_type,
      actor: "memory_gateway",
      caused_by: nil,
      payload: JSON::Any.new(payload).to_json,
    )
    graph.emit(event)
    event
  end

  def self._get_item(graph : Chronicle::GraphProjection, artifact_id : String) : Chronicle::GraphObject?
    obj = graph.get_object(artifact_id)
    return nil if obj.nil? || obj.type != "memory_item"

    obj
  end

  # The unresolved proposal for *artifact_id* (and direction), or nil.
  def self.open_proposal_for(graph : Chronicle::GraphProjection, artifact_id : String, direction : PromotionDirection? = nil) : Chronicle::GraphObject?
    graph.objects(type: "memory_promotion_proposal").find do |obj|
      data = JSON.parse(obj.data)
      data["artifact_id"]?.try(&.as_s?) == artifact_id &&
        data["status"]?.try(&.as_s?) == "proposed" &&
        (direction.nil? || PromotionDirection.parse?(data["direction"]?.try(&.as_s?) || "") == direction)
    end
  end

  # Record one promote/demote proposal for an exact item version.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream rule validation
  def self.propose_memory_promotion_fn(graph : Chronicle::GraphProjection, artifact_id : String, direction : PromotionDirection, reliability_verdict : String, helped_outcomes : Int32, evidence_event_ids : Array(String), rationale : String, proposed_by : String = "memory_promotion_proposer", is_fixture : Bool = false, reader : Chronicle::GraphProjection? = nil) : Hash(String, JSON::Any)
    item = _get_item(graph, artifact_id)
    raise Chronicle::Packs::PackError.new("unknown memory_item #{artifact_id.inspect}") if item.nil?
    raise Chronicle::Packs::PackError.new("a proposal requires reliability evidence event ids") if evidence_event_ids.empty?

    rules = PromotionRules::RULES
    item_data = JSON.parse(item.data).as_h
    status = item_data["promotion_status"]?.try(&.as_s?) || "admitted"
    if direction == PromotionDirection::Promote
      if status == "promoted"
        return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "reason" => JSON::Any.new("already promoted")}
      end
      if reliability_verdict != rules["required_verdict"].as(String)
        raise Chronicle::Packs::PackError.new("promotion proposals require verdict #{rules["required_verdict"].as(String).inspect}; got #{reliability_verdict.inspect}")
      end
      if helped_outcomes < rules["min_helped_outcomes"].as(Int32)
        raise Chronicle::Packs::PackError.new("promotion proposals require >= #{rules["min_helped_outcomes"]} helped outcomes; got #{helped_outcomes}")
      end
    else
      if status != "promoted"
        return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "reason" => JSON::Any.new("demotion applies to promoted versions only")}
      end
      unless (rules["demote_on_verdicts"].as(Array(String))).includes?(JSON::Any.new(reliability_verdict))
        raise Chronicle::Packs::PackError.new("demotion proposals require a verdict in #{rules["demote_on_verdicts"]}; got #{reliability_verdict.inspect}")
      end
    end

    existing = open_proposal_for(reader || graph, artifact_id, direction)
    if existing
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "proposal" => JSON::Any.new(existing.id)}
    end

    version = item_data["artifact_version"]?.try(&.as_s?) || "1"
    proposal_id = "memprom_#{artifact_id}_#{version}_#{direction}_#{evidence_event_ids.size}"
    proposal = MemoryPromotionProposal.new(
      proposal_id, artifact_id, version,
      direction: direction,
      status: ProposalStatus::Proposed,
      reliability_verdict: reliability_verdict, helped_outcomes: helped_outcomes,
      evidence_event_ids: evidence_event_ids,
      rule_id: rules["rule_id"].as(String), rule_version: rules["rule_version"].as(Int32),
      rationale: rationale, proposed_by: proposed_by, is_fixture: is_fixture,
    )
    proposal_obj = graph.add_object("memory_promotion_proposal", proposal.to_json)
    graph.add_relation(proposal_obj.id, item.id, "promotion_proposal_for")
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "proposal" => JSON::Any.new(proposal_obj.id)}
  end

  # Resolve one proposal — the ONLY path that promotes or demotes.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream resolution
  def self.resolve_memory_promotion_fn(graph : Chronicle::GraphProjection, proposal_id : String, approve : Bool, approver : String, note : String = "") : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("resolution requires a non-empty approver") if approver.strip.empty?

    proposal = graph.objects(type: "memory_promotion_proposal").find { |obj| JSON.parse(obj.data)["proposal_id"]?.try(&.as_s?) == proposal_id }
    raise Chronicle::Packs::PackError.new("unknown memory promotion proposal #{proposal_id.inspect}") if proposal.nil?

    proposal_data = JSON.parse(proposal.data).as_h
    unless proposal_data["status"]?.try(&.as_s?) == "proposed"
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "reason" => JSON::Any.new("proposal already resolved")}
    end
    item = _get_item(graph, proposal_data["artifact_id"]?.try(&.as_s?) || "")
    raise Chronicle::Packs::PackError.new("proposal references an unknown memory_item") if item.nil?

    if !approve
      merged = proposal_data.dup
      merged["status"] = JSON::Any.new("rejected")
      merged["resolved_by"] = JSON::Any.new(approver)
      metadata = (proposal_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
      metadata["note"] = JSON::Any.new(note)
      merged["metadata"] = JSON::Any.new(metadata)
      graph.patch_object(proposal.id, JSON::Any.new(merged).to_json)
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "resolution" => JSON::Any.new("rejected")}
    end

    direction = PromotionDirection.parse?(proposal_data["direction"]?.try(&.as_s?) || "promote") || PromotionDirection::Promote
    version = proposal_data["artifact_version"]?.try(&.as_s?) || "1"
    event_type = direction == PromotionDirection::Promote ? "memory.promoted" : "memory.demoted"
    new_status = direction == PromotionDirection::Promote ? "promoted" : "demoted"
    item_data = JSON.parse(item.data).as_h
    if item_data["promotion_status"]?.try(&.as_s?) == new_status
      merged = proposal_data.dup
      merged["status"] = JSON::Any.new("approved")
      merged["resolved_by"] = JSON::Any.new(approver)
      graph.patch_object(proposal.id, JSON::Any.new(merged).to_json)
      return {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(false), "reason" => JSON::Any.new("already #{new_status}")}
    end

    event = _emit_event(graph, event_type, {
      "artifact_id"         => JSON::Any.new(item.id),
      "artifact_version"    => JSON::Any.new(version),
      "artifact_type"       => JSON::Any.new("memory_item"),
      "proposal_id"         => JSON::Any.new(proposal_id),
      "direction"           => JSON::Any.new(direction.to_s),
      "approver"            => JSON::Any.new(approver),
      "note"                => JSON::Any.new(note),
      "reliability_verdict" => proposal_data["reliability_verdict"]? || JSON::Any.new(""),
      "evidence_event_ids"  => proposal_data["evidence_event_ids"]? || JSON::Any.new([] of JSON::Any),
      "rule_id"             => proposal_data["rule_id"]? || JSON::Any.new(""),
      "rule_version"        => proposal_data["rule_version"]? || JSON::Any.new(0),
      "is_fixture"          => proposal_data["is_fixture"]? || JSON::Any.new(false),
    })
    history = (item_data["promotion_history"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h)
    history << {
      "event_id"     => JSON::Any.new(event.id),
      "proposal_id"  => JSON::Any.new(proposal_id),
      "direction"    => JSON::Any.new(direction.to_s),
      "approver"     => JSON::Any.new(approver),
      "prior_status" => item_data["promotion_status"]? || JSON::Any.new("admitted"),
      "new_status"   => JSON::Any.new(new_status),
    }
    item_merged = item_data.dup
    item_merged["promotion_status"] = JSON::Any.new(new_status)
    item_merged["promotion_history"] = JSON::Any.new(history.map { |entry| JSON::Any.new(entry) })
    graph.patch_object(item.id, JSON::Any.new(item_merged).to_json)

    proposal_merged = proposal_data.dup
    proposal_merged["status"] = JSON::Any.new("approved")
    proposal_merged["resolved_by"] = JSON::Any.new(approver)
    proposal_merged["resolved_event_id"] = JSON::Any.new(event.id)
    graph.patch_object(proposal.id, JSON::Any.new(proposal_merged).to_json)

    {"ok" => JSON::Any.new(true), "changed" => JSON::Any.new(true), "resolution" => JSON::Any.new("approved"), "event_id" => JSON::Any.new(event.id), "item" => JSON::Any.new(item.id)}
  end

  # Source refs whose recorded lineage forbids a replay claim (ADR 0015).
  def self._source_replay_gaps(graph : Chronicle::GraphProjection, item : Chronicle::GraphObject) : Array(String)
    gaps = [] of String
    item_data = JSON.parse(item.data).as_h
    refs = (item_data["source_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    candidate_id = item_data["candidate_id"]?.try(&.as_s?)
    if candidate_id
      candidate = graph.get_object(candidate_id)
      if candidate
        refs.concat((JSON.parse(candidate.data)["source_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s))
      end
    end
    refs.each do |ref|
      source = graph.get_object(ref)
      next if source.nil?

      source_data = JSON.parse(source.data).as_h
      metadata = source_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
      acquisition = source_data["acquisition"]?.try(&.as_h) || metadata["acquisition"]?.try(&.as_h) || {} of String => JSON::Any
      replay_complete = source_data["replay_complete"]?.try(&.as_bool?) || metadata["replay_complete"]?.try(&.as_bool?)
      if replay_complete == false
        gaps << ref
      elsif acquisition["replay_mode"]?.try(&.as_s?) == "reference_only"
        gaps << ref
      end
    end
    gaps
  end

  # Earn replay.verified for one PROMOTED memory item version — the memory
  # half of the replay.verified emitter (SCORING_CONTRACT). Three recorded
  # checks: replay-complete lineage, admission re-derivation, recorded
  # retrieval through the same path recall uses. The port's backend IS the
  # graph store, so retrieval rides the graph's recorded embedding path.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream three-check verification
  def self.verify_memory_replay_fn(graph : Chronicle::GraphProjection, artifact_id : String, actor : String = "memory_gateway") : Hash(String, JSON::Any)
    item = _get_item(graph, artifact_id)
    raise Chronicle::Packs::PackError.new("unknown memory_item #{artifact_id.inspect}") if item.nil?

    item_data = JSON.parse(item.data).as_h
    status = item_data["promotion_status"]?.try(&.as_s?) || "admitted"
    unless status == "promoted"
      raise Chronicle::Packs::PackError.new("replay verification applies to promoted memory versions only; this item is #{status.inspect}")
    end
    version = item_data["artifact_version"]?.try(&.as_s?) || "1"

    gaps = _source_replay_gaps(graph, item)
    if !gaps.empty?
      raise MemoryReplayIncompleteError.new("memory_item #{artifact_id.inspect} has reference_only / replay-incomplete source lineage #{gaps}; ADR 0015: such lineage may not support a replay.verified claim")
    end

    checks = [] of Hash(String, JSON::Any)

    candidate_id = item_data["candidate_id"]?.try(&.as_s?)
    candidate = candidate_id ? graph.get_object(candidate_id) : nil
    if candidate.nil?
      raise MemoryReplayIncompleteError.new("memory_item #{artifact_id.inspect} has no recorded memory_candidate; the admission decision cannot be re-derived from the log")
    end
    candidate_text = JSON.parse(candidate.data)["text"]?.try(&.as_s?) || ""
    if Backend._normalize_text(candidate_text) != Backend._normalize_text(item_data["text"]?.try(&.as_s?) || "")
      raise MemoryReplayIncompleteError.new("memory_item #{artifact_id.inspect} text no longer re-derives from its recorded candidate — replay check failed, not skipped")
    end
    checks << {"check" => JSON::Any.new("admission_rederivation"), "passed" => JSON::Any.new(true), "candidate_id" => candidate_id ? JSON::Any.new(candidate_id) : JSON::Any.new(nil)}

    results = Backend.retrieve_by_query(graph, item_data["text"]?.try(&.as_s?) || "", top_k: 10, min_score: 0.0)
    retrieved_ids = results.map { |row| row["item_id"]?.try(&.as_s?) || "" }
    unless retrieved_ids.includes?(item.id)
      raise MemoryReplayIncompleteError.new("memory_item #{artifact_id.inspect} is no longer retrievable from the stored artifact — replay check failed, not skipped")
    end
    checks << {"check" => JSON::Any.new("recorded_retrieval"), "passed" => JSON::Any.new(true), "results_considered" => JSON::Any.new(retrieved_ids.size)}

    prior = graph.events.find do |e|
      e.type == "replay.verified" &&
        (JSON.parse(e.payload)["subject_id"]?.try(&.as_s?) == item.id) &&
        (JSON.parse(e.payload)["subject_version"]?.try(&.as_s?) == version)
    end
    if prior
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "event_id" => JSON::Any.new(prior.id)}
    end

    event = _emit_event(graph, "replay.verified", {
      "subject_id"      => JSON::Any.new(item.id),
      "subject_version" => JSON::Any.new(version),
      "subject_type"    => JSON::Any.new("memory_item"),
      "method"          => JSON::Any.new("recorded_admission_and_retrieval_recheck"),
      "checks"          => JSON::Any.new(checks.map { |check| JSON::Any.new(check) }),
      "actor"           => JSON::Any.new(actor),
      "is_fixture"      => (item_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["is_fixture"]? || JSON::Any.new(false),
    })
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "event_id" => JSON::Any.new(event.id)}
  end
end

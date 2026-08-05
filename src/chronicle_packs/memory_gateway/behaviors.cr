require "json"

module Chronicle::Packs::MemoryGateway
  # Memory Gateway behaviors. Ported from upstream
  # packs/memory_gateway/behaviors.py (slice 1: candidate_evaluator,
  # memory_writer, memory_retriever, memory_ranker,
  # memory_reliability_applier). memory_promotion_proposer depends on the
  # promotion module (deferred).

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module Admission
    GUIDANCE_CATEGORIES = Set(String).new(["instruction", "preference", "decision"])
    TRUSTED_ROLES       = Set(String).new(["owner", "admin", "collaborator"])
  end

  # Resolve the originating subject (user) from a candidate's source objects.
  def self._derive_subject_ref(graph : Chronicle::GraphProjection, source_ids : Array(String)) : String?
    source_ids.each do |sid|
      src = graph.get_object(sid)
      next if src.nil?

      sender = JSON.parse(src.data)["sender_ref"]?.try(&.as_s?)
      return sender if sender
    end
    nil
  end

  # Classify evidence-backed candidates before judging their content.
  def self._source_admission_policy(graph : Chronicle::GraphProjection, candidate_data : Hash(String, JSON::Any)) : {String, String}
    (candidate_data["source_ids"]?.try(&.as_a) || [] of JSON::Any).each do |source_ref|
      source = graph.get_object(source_ref.as_s)
      next if source.nil? || source.type != "activity_evidence"

      data = JSON.parse(source.data).as_h
      metadata = data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
      flags = metadata["injection_flags"]?.try(&.as_a) || [] of JSON::Any
      if !flags.empty?
        return {"reject", "untrusted evidence carries injection flags: #{flags.map(&.as_s).join(", ")}"}
      end
      policy = metadata["memory_admission"]?.try(&.as_s?) || ""
      if policy == "reject"
        return {"reject", "source evidence explicitly forbids memory admission"}
      end
      if policy == "review_required"
        trust = metadata["source_trust"]?.try(&.as_s?) || "unverified"
        return {"review", "#{trust} evidence requires corroboration or owner review"}
      end
    end
    {"eligible", "source admission policy permits evaluation"}
  end

  # Decide whether this candidate's ORIGIN permits memorization.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream provenance policy
  def self._provenance_verdict(graph : Chronicle::GraphProjection, candidate_data : Hash(String, JSON::Any), settings : MemoryGatewaySettings) : {String, String}
    return {"eligible", "admission policy off"} if settings.provenance_admission == "off"

    source_policy, source_reason = _source_admission_policy(graph, candidate_data)
    return {source_policy, source_reason} if source_policy != "eligible"

    sender_ref = nil
    kind = nil
    (candidate_data["source_ids"]?.try(&.as_a) || [] of JSON::Any).each do |source_ref|
      src = graph.get_object(source_ref.as_s)
      next if src.nil?

      sdata = JSON.parse(src.data).as_h
      kind = sdata["kind"]?.try(&.as_s?)
      if sender_ref = sdata["sender_ref"]?.try(&.as_s?)
        break
      end
    end
    if kind == "chat_message"
      return {"eligible", "conversational source (speaker addresses the assistant)"}
    end
    if sender_ref.nil?
      return {"eligible", "no external-source admission restriction"}
    end
    if !Admission::GUIDANCE_CATEGORIES.includes?(candidate_data["category"]?.try(&.as_s?) || "")
      return {"eligible", "knowledge category from #{sender_ref.inspect} (subject-scoped)"}
    end

    any_principals = !graph.objects(type: "principal").empty?
    return {"eligible", "no principals registered — provenance unverifiable"} unless any_principals

    principal = IdentityAuth.lookup_principal_fn(graph, sender_ref)
    role = principal ? (principal["role"]?.try(&.as_s?)) : nil
    if role && Admission::TRUSTED_ROLES.includes?(role)
      return {"eligible", "guidance from trusted principal #{sender_ref.inspect} (#{role})"}
    end
    {"reject", "guidance category #{candidate_data["category"]?.try(&.as_s?).inspect} from non-conversational source by untrusted sender #{sender_ref.inspect} (role=#{role.inspect}) — documents don't give orders"}
  end

  # Evaluate a memory_candidate and accept or reject it.
  @[Chronicle::Packs::Annotations::Behavior(name: "candidate_evaluator", on: ["object.created"], where: {"type" => "memory_candidate"}, creates: ["evaluation"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream acceptance policy
  def candidate_evaluator(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MemoryGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    candidate_id = payload["id"]?.try(&.as_s?)
    return if candidate_id.nil?

    candidate_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    confidence = candidate_data["confidence"]?.try(&.as_f?) || 0.0
    category = candidate_data["category"]?.try(&.as_s?)
    text = candidate_data["text"]?.try(&.as_s?) || ""
    frame_id = candidate_data["frame_id"]?.try(&.as_s?)
    return if text.empty?

    admission, prov_reason = _provenance_verdict(graph, candidate_data, settings)
    is_priority_category = category && settings.auto_accept_categories.includes?(category)
    threshold = is_priority_category ? settings.auto_accept_min_confidence : settings.acceptance_threshold

    judgment, rationale, accepted = if admission == "review"
                                      {"requires_review", "Provenance: #{prov_reason}", false}
                                    elsif admission == "reject"
                                      {"rejected", "Provenance: #{prov_reason}", false}
                                    elsif confidence >= threshold
                                      {"accepted", "Confidence #{confidence.round(2)} >= threshold #{threshold.round(2)}" + (is_priority_category ? " (relieved for priority category '#{category}')." : ".") + " Provenance: #{prov_reason}", true}
                                    else
                                      {"rejected", "Confidence #{confidence.round(2)} < threshold #{threshold.round(2)}. Candidate does not meet the minimum quality bar.", false}
                                    end

    eval_obj = graph.add_object("evaluation", JSON.build do |json|
      json.object do
        json.field "subject_id", candidate_id
        json.field "subject_type", "memory_candidate"
        json.field "judgment", judgment
        json.field "rationale", rationale
        json.field "evaluator", "memory_gateway.candidate_evaluator"
        json.field "score", confidence
        json.field "frame_id", frame_id ? JSON::Any.new(frame_id) : JSON::Any.new(nil)
        json.field "metadata", JSON::Any.new({"category" => category ? JSON::Any.new(category) : JSON::Any.new(nil), "threshold" => JSON::Any.new(threshold), "admission" => JSON::Any.new(admission)})
      end
    end)
    graph.add_relation(eval_obj.id, candidate_id, "evaluates")

    if accepted
      if current = graph.get_object(candidate_id)
        data = JSON.parse(current.data).as_h
        data["accepted"] = JSON::Any.new(true)
        data["evaluation_id"] = JSON::Any.new(eval_obj.id)
        graph.patch_object(candidate_id, JSON::Any.new(data).to_json)
      end
    end
  end

  # Promote an accepted memory_candidate to a MemoryItem.
  @[Chronicle::Packs::Annotations::Behavior(name: "memory_writer", on: ["object.created"], where: {"type" => "evaluation"}, creates: ["memory_item"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream write path
  def memory_writer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MemoryGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    eval_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless eval_data["judgment"]?.try(&.as_s?) == "accepted"
    return unless eval_data["subject_type"]?.try(&.as_s?) == "memory_candidate"

    subject_id = eval_data["subject_id"]?.try(&.as_s?)
    return if subject_id.nil?

    candidate = graph.get_object(subject_id)
    return if candidate.nil?

    candidate_data = JSON.parse(candidate.data).as_h
    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
    text = candidate_data["text"]?.try(&.as_s?) || ""
    subject_ref = candidate_data["subject_ref"]?.try(&.as_s?)
    if subject_ref.nil?
      subject_ref = _derive_subject_ref(graph, candidate_data["source_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String)
    end

    existing_id = Backend.find_by_text(graph, text, subject_ref)
    if existing_id
      if subject_ref && Backend.get_subject(graph, existing_id).nil?
        Backend.set_subject(graph, existing_id, subject_ref)
      end
      graph.add_relation(subject_id, existing_id, "accepted_as")
      return
    end

    item = MemoryItem.new(
      text,
      category: candidate_data["category"]?.try(&.as_s?),
      confidence: candidate_data["confidence"]?.try(&.as_f?) || 0.7,
      source_ids: candidate_data["source_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      candidate_id: subject_id, created_at: now, retrieval_count: 0,
      subject_ref: subject_ref,
    )
    item_obj = graph.add_object("memory_item", item.to_json)

    if settings.max_items > 0
      Backend.enforce_limit(graph, settings.max_items)
    end
    graph.add_relation(subject_id, item_obj.id, "accepted_as")
  end

  # Fulfill a memory_retrieval_request by querying the backend.
  @[Chronicle::Packs::Annotations::Behavior(name: "memory_retriever", on: ["object.created"], where: {"type" => "memory_retrieval_request"}, creates: ["memory_retrieval"])]
  def memory_retriever(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MemoryGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    request_id = payload["id"]?.try(&.as_s?)
    return if request_id.nil?

    request_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    query = request_data["query"]?.try(&.as_s?) || ""
    return if query.empty?

    top_k = request_data["top_k"]?.try(&.as_i?) || settings.retrieval_top_k
    min_score = request_data["min_score"]?.try(&.as_f?) || settings.min_retrieval_score
    category = request_data["category"]?.try(&.as_s?)
    behavior_name = request_data["behavior_name"]?.try(&.as_s?)
    frame_id = request_data["frame_id"]?.try(&.as_s?)
    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")

    results = Backend.retrieve_by_query(graph, query, top_k: top_k, min_score: min_score, category: category, exclude_frame_id: frame_id)
    item_ids = results.map(&.["item_id"].as_s)
    item_ids.each { |item_id| Backend.update_retrieval(graph, item_id) }

    backend_results = {} of String => JSON::Any
    results.each do |result|
      backend_results[result["item_id"].as_s] = JSON::Any.new({
        "score"                  => result["score"]? || JSON::Any.new(0.0),
        "raw_score"              => result["raw_score"]? || result["score"]? || JSON::Any.new(0.0),
        "reliability_verdict"    => result["reliability_verdict"]? || JSON::Any.new("weak"),
        "reliability_multiplier" => result["reliability_multiplier"]? || JSON::Any.new(1.0),
      })
    end
    retrieval = MemoryRetrieval.new(query, request_id: request_id, behavior_name: behavior_name, frame_id: frame_id, results_count: item_ids.size, item_ids: item_ids, retrieved_at: now, metadata: {"backend_results" => JSON::Any.new(backend_results)})
    retrieval_obj = graph.add_object("memory_retrieval", retrieval.to_json)
    graph.add_relation(request_id, retrieval_obj.id, "fulfilled_by")
    item_ids.each { |item_id| graph.add_relation(item_id, retrieval_obj.id, "ranked_in") }
  end

  # Score each MemoryItem returned in a retrieval by query relevance.
  @[Chronicle::Packs::Annotations::Behavior(name: "memory_ranker", on: ["object.created"], where: {"type" => "memory_retrieval"}, creates: ["memory_ranking"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream ranking loop
  def memory_ranker(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MemoryGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    retrieval_id = payload["id"]?.try(&.as_s?)
    return if retrieval_id.nil?

    retrieval_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    query = retrieval_data["query"]?.try(&.as_s?) || ""
    item_ids = retrieval_data["item_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    return if query.empty? || item_ids.empty?

    backend_results = (retrieval_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["backend_results"]?.try(&.as_h) || {} of String => JSON::Any
    scored = [] of {Float64, String, String, Hash(String, JSON::Any)}
    item_ids.each do |item_id|
      item = graph.get_object(item_id)
      next if item.nil?

      item_text = JSON.parse(item.data)["text"]?.try(&.as_s?) || ""
      backend_result = backend_results[item_id]?.try(&.as_h) || {} of String => JSON::Any
      score = backend_result["score"]?.try(&.as_f?) || Backend.lexical_score(query, item_text)
      scored << {score, item_id, item_text, backend_result}
    end
    scored.sort_by! { |score, _item_id, _text, _br| -score }

    scored.each_with_index do |(score, item_id, _item_text, backend_result), index|
      ranking = MemoryRanking.new(
        retrieval_id, item_id, score.round(4),
        reason: "Outcome-aware relevance #{score.round(2)}; reliability #{backend_result["reliability_verdict"]?.try(&.as_s?) || "weak"} at ×#{(backend_result["reliability_multiplier"]?.try(&.as_f?) || 1.0).round(2)}.",
        rank: index + 1, metadata: backend_result,
      )
      ranking_obj = graph.add_object("memory_ranking", ranking.to_json)
      graph.add_relation(ranking_obj.id, retrieval_id, "scored_by")
    end
  end

  # Apply outcome-derived reliability to retrieval, reversibly and visibly.
  @[Chronicle::Packs::Annotations::Behavior(name: "memory_reliability_applier", on: ["reliability.changed"])]
  def memory_reliability_applier(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MemoryGatewaySettings) : Nil
    payload = JSON.parse(event.payload).as_h
    return unless payload["artifact_type"]?.try(&.as_s?) == "memory_item"

    item_id = payload["artifact_id"]?.try(&.as_s?) || ""
    item = graph.get_object(item_id)
    return if item.nil? || item.type != "memory_item"

    verdict = payload["verdict"]?.try(&.as_s?) || "weak"
    multiplier = payload["retrieval_multiplier"]?.try(&.as_f?) || 1.0
    Backend.set_reliability(graph, item_id, verdict, multiplier)
    if current = graph.get_object(item_id)
      memory_item = MemoryItem.from_json(current.data)
      parsed_verdict = ReliabilityVerdict.parse?(verdict) || ReliabilityVerdict::Weak
      graph.patch_object(item_id, memory_item.copy_with(reliability_verdict: parsed_verdict, reliability_multiplier: multiplier, reliability_event_id: event.id).to_json)
    end
  end
end

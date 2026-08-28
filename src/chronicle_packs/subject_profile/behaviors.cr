require "json"
require "digest"

module Chronicle::Packs::SubjectProfile
  # Subject Profile Pack behaviors. Ported from upstream
  # packs/subject_profile/behaviors.py.
  #
  # apply_subject_fact_verdict — subject_fact_verdict.created (status
  #                              proposed) → subject_fact (promoted),
  #                              subject_contradiction
  #
  # An explicit review decision over one profile_candidate promotes an
  # evidence-backed subject fact (scope-guarded to owner_profile evidence),
  # or rejects/invalidates the candidate. A corrected value that conflicts
  # with a prior promoted fact records a contradiction.

  # Deterministic subject-scoped identity (upstream _stable_id): SHA-256 over
  # the `\x1f`-joined parts, truncated to 24 hex chars.
  def self._stable_id(prefix : String, *parts) : String
    raw = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(raw)[0, 24]}"
  end

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json, actor: "subject_profile.apply_subject_fact_verdict")
  end

  # Apply an explicit review decision over one profile candidate.
  @[Chronicle::Packs::Annotations::Behavior(name: "apply_subject_fact_verdict", on: ["object.created"], where: {"type" => "subject_fact_verdict", "data.status" => "proposed"}, creates: ["subject_fact", "subject_contradiction"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream apply_subject_fact_verdict verdict/scope/value/contradiction branches
  def apply_subject_fact_verdict(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : SubjectProfileSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    verdict_id = payload["id"]?.try(&.as_s?)
    return if verdict_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    candidate = graph.get_object(data["candidate_id"]?.try(&.as_s?) || "")
    if candidate.nil? || candidate.type != "profile_candidate"
      _merge_patch(graph, verdict_id, {"status" => JSON::Any.new("failed")})
      return
    end

    decision = data["decision"]?.try(&.as_s?) || ""
    if decision == "reject"
      _merge_patch(graph, verdict_id, {"status" => JSON::Any.new("applied")})
      _merge_patch(graph, candidate.id, {
        "status"              => JSON::Any.new("invalidated"),
        "invalidation_reason" => JSON::Any.new("owner_rejected"),
      })
      return
    end

    cdata = JSON.parse(candidate.data).as_h
    subject_ref = data["subject_ref"]?.try(&.as_s?) || settings.owner_subject_ref
    evidence_id = cdata["evidence_id"]?.try(&.as_s?) || ""
    # Scope is a security boundary. A review decision can correct a value but
    # cannot silently reinterpret multi-subject connector content as being
    # about the owner.
    evidence = evidence_id.empty? ? nil : graph.get_object(evidence_id)
    source_surface_id : String? = nil
    scope_ok =
      if ev = evidence
        ev_data = JSON.parse(ev.data).as_h
        nm = ev_data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
        if nm["subject_scope"]?.try(&.as_s?) == "owner_profile"
          source_surface_id = ev_data["source_surface_id"]?.try(&.as_s?)
          true
        else
          false
        end
      else
        false
      end
    unless scope_ok
      _merge_patch(graph, verdict_id, {
        "status"   => JSON::Any.new("failed"),
        "metadata" => JSON::Any.new({"error" => JSON::Any.new("owner_subject_scope_required")}),
      })
      return
    end

    attribute = cdata["attribute"]?.try(&.as_s?) || "profile_statement"
    value = (data["corrected_value"]?.try(&.as_s?) || cdata["value"]?.try(&.as_s?) || cdata["text"]?.try(&.as_s?) || "").strip
    if value.empty?
      _merge_patch(graph, verdict_id, {
        "status"   => JSON::Any.new("failed"),
        "metadata" => JSON::Any.new({"error" => JSON::Any.new("empty_value")}),
      })
      return
    end

    active = [] of Chronicle::GraphObject
    graph.objects(type: "subject_fact").each do |fact|
      fd = JSON.parse(fact.data).as_h
      if fd["subject_ref"]?.try(&.as_s?) == subject_ref &&
         fd["attribute"]?.try(&.as_s?) == attribute &&
         fd["status"]?.try(&.as_s?) == "promoted" &&
         fd["value"]?.try(&.as_s?) != value
        active << fact
      end
    end

    cmeta = cdata["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    confidence = cdata["confidence"]?.try(&.as_f?) || 0.5
    text = cdata["text"]?.try(&.as_s?)
    text = value if text.nil? || text.empty?

    fact = graph.add_object("subject_fact", SubjectFact.new(
      fact_identity: _stable_id("subject_fact", subject_ref, attribute, value, candidate.id),
      subject_ref: subject_ref,
      attribute: attribute,
      value: value,
      text: text,
      status: FactStatus::Promoted,
      confidence: confidence,
      trust: settings.confirmed_trust,
      candidate_id: candidate.id,
      annotation_id: cmeta["annotation_id"]?.try(&.as_s?),
      evidence_id: evidence_id,
      source_surface_id: source_surface_id,
      verdict_id: verdict_id,
      supersedes_fact_id: nil,
      metadata: {
        "decision"   => JSON::Any.new(decision),
        "decided_by" => data["decided_by"]? || JSON::Any.new(nil),
      },
    ).to_json, actor: "subject_profile.apply_subject_fact_verdict")
    graph.add_relation(fact.id, candidate.id, "promoted_from_profile_candidate", actor: "subject_profile.apply_subject_fact_verdict")
    graph.add_relation(fact.id, evidence_id, "subject_fact_grounded_in", actor: "subject_profile.apply_subject_fact_verdict")
    _merge_patch(graph, verdict_id, {
      "status"         => JSON::Any.new("applied"),
      "result_fact_id" => JSON::Any.new(fact.id),
    })
    active.each do |prior|
      _merge_patch(graph, prior.id, {"status" => JSON::Any.new("contradicted")})
      contradiction = graph.add_object("subject_contradiction", SubjectContradiction.new(
        contradiction_identity: _stable_id("subject_contradiction", subject_ref, attribute, prior.id, fact.id),
        subject_ref: subject_ref,
        attribute: attribute,
        fact_ids: [prior.id, fact.id],
        status: ContradictionStatus::Open,
        winning_fact_id: nil,
        rationale: "conflicting owner-confirmed values",
        metadata: {} of String => JSON::Any,
      ).to_json, actor: "subject_profile.apply_subject_fact_verdict")
      graph.add_relation(contradiction.id, prior.id, "contradiction_involves", actor: "subject_profile.apply_subject_fact_verdict")
      graph.add_relation(contradiction.id, fact.id, "contradiction_involves", actor: "subject_profile.apply_subject_fact_verdict")
    end
  end
end

require "json"
require "digest"

module Chronicle::Packs::SubjectProfile
  # Subject Profile Pack tools. Ported from upstream
  # packs/subject_profile/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Create a subject_fact_verdict over a profile candidate, triggering
  # apply_subject_fact_verdict.
  def self.review_subject_fact_fn(
    graph : Chronicle::GraphProjection,
    candidate_id : String,
    decision : String,
    subject_ref : String = "owner",
    corrected_value : String? = nil,
    decided_by : String = "owner",
    rationale : String = "",
  ) : Hash(String, JSON::Any)
    verdict = graph.add_object("subject_fact_verdict", SubjectFactVerdict.new(
      candidate_id: candidate_id,
      subject_ref: subject_ref,
      decision: VerdictDecision.parse?(decision) || VerdictDecision::Confirm,
      corrected_value: corrected_value,
      decided_by: decided_by,
      rationale: rationale,
      status: VerdictStatus::Proposed,
    ).to_json, actor: "subject_profile")
    graph.add_relation(verdict.id, candidate_id, "verdict_for_profile_candidate", actor: "subject_profile")
    {"verdict_id" => JSON::Any.new(verdict.id), "status" => JSON::Any.new("proposed")}
  end

  # Forget a subject fact through an auditable superseding tombstone.
  def self.forget_subject_fact_fn(
    graph : Chronicle::GraphProjection,
    fact_id : String,
    forgotten_by : String = "owner",
    rationale : String = "owner requested forget",
  ) : Hash(String, JSON::Any)
    fact = graph.get_object(fact_id)
    if fact.nil? || fact.type != "subject_fact"
      raise Chronicle::Packs::PackError.new("unknown subject_fact #{fact_id.inspect}")
    end
    data = JSON.parse(fact.data).as_h
    raw = "#{fact_id}\x1f#{forgotten_by}\x1f#{rationale}"
    tombstone = graph.add_object("subject_fact", SubjectFact.new(
      fact_identity: "subject_fact_forget_#{Digest::SHA256.hexdigest(raw)[0, 24]}",
      subject_ref: data["subject_ref"].as_s,
      attribute: data["attribute"].as_s,
      value: data["value"].as_s,
      text: data["text"].as_s,
      status: FactStatus::Forgotten,
      confidence: data["confidence"]?.try(&.as_f?) || 0.5,
      trust: data["trust"]?.try(&.as_f?) || 0.5,
      candidate_id: data["candidate_id"]?.try(&.as_s?),
      annotation_id: data["annotation_id"]?.try(&.as_s?),
      evidence_id: data["evidence_id"]?.try(&.as_s?),
      source_surface_id: data["source_surface_id"]?.try(&.as_s?),
      verdict_id: data["verdict_id"]?.try(&.as_s?),
      supersedes_fact_id: fact_id,
      metadata: {
        "forgotten_by" => JSON::Any.new(forgotten_by),
        "rationale"    => JSON::Any.new(rationale),
      },
    ).to_json, actor: "subject_profile")
    _merge_patch(graph, fact_id, {"status" => JSON::Any.new("superseded")})
    graph.add_relation(tombstone.id, fact_id, "subject_fact_supersedes", actor: "subject_profile")
    {"fact_id" => JSON::Any.new(fact_id), "tombstone_fact_id" => JSON::Any.new(tombstone.id), "status" => JSON::Any.new("forgotten")}
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "subject_profile tools require a bound graph (set SubjectProfile.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "review_subject_fact", description: "Confirm, reject, or correct an evidence-backed profile candidate.", deterministic: true)]
  def review_subject_fact_tool(args : String) : String
    input = JSON.parse(args).as_h
    review_subject_fact_fn(
      bound_graph_or_raise,
      input["candidate_id"]?.try(&.as_s?) || "",
      input["decision"]?.try(&.as_s?) || "confirm",
      subject_ref: input["subject_ref"]?.try(&.as_s?) || "owner",
      corrected_value: input["corrected_value"]?.try(&.as_s?),
    ).to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "forget_subject_fact", description: "Forget a subject fact through an auditable superseding tombstone.", deterministic: true)]
  def forget_subject_fact_tool(args : String) : String
    input = JSON.parse(args).as_h
    forget_subject_fact_fn(
      bound_graph_or_raise,
      input["fact_id"]?.try(&.as_s?) || "",
    ).to_json
  end
end

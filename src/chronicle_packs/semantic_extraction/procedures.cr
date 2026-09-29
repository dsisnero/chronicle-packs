require "json"
require "digest"

module Chronicle::Packs::SemanticExtraction
  # First ADR 0029 pilot: guarded dynamic-to-deterministic extraction.
  # Ported from upstream packs/semantic_extraction/procedures.py. The
  # candidate is declarative graph state around a shipped deterministic
  # parser; no generated code is imported. The port evaluates on the graph
  # directly (the evaluation is deterministic and only adds audit objects)
  # instead of a runtime fork.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module ProcedureConstants
    REQUEST_PROCEDURE_REF = "semantic.request_rule@0.1.0"
    REFERENCE_REF         = "semantic.llm@0.1.0"
    POLICY_ID             = "semantic.proceduralization@1"
    REQUEST_CUE           = /\b(please|can you|could you|would you|will you|need you to|action item|to[- ]?do|follow up|send me|let me know)\b/i
  end

  # Deterministic extractor for explicit communication requests.
  module Extractors
    class RequestRuleExtractorV1 < AnnotationExtractor
      property extractor_id : String = "semantic.request_rule"
      property extractor_version : String = "0.1.0"

      def implemented_facets : Array(String)
        ["relation_mention"]
      end

      def config : Hash(String, JSON::Any)
        {
          "policy_id"         => JSON::Any.new(ProcedureConstants::POLICY_ID),
          "cue_pattern_id"    => JSON::Any.new("communication.explicit_request@1"),
          "sentence_boundary" => JSON::Any.new("semantic.deterministic._sentences@1"),
        }
      end

      def extract(content : String, metadata : Hash(String, JSON::Any), facets : Array(String)) : Array(AnnotationDraft)
        return [] of AnnotationDraft unless facets.includes?("relation_mention")

        rows = [] of AnnotationDraft
        Extractors._sentences(content).each do |start, stop, sentence|
          match = ProcedureConstants::REQUEST_CUE.match(sentence)
          next if match.nil?

          rows << AnnotationDraft.new(
            "relation_mention",
            {"text" => JSON::Any.new(sentence), "subject" => JSON::Any.new("sender"), "predicate" => JSON::Any.new("requests"), "object" => JSON::Any.new(sentence)},
            start, stop, sentence, 0.85,
            metadata: {"procedure_ref" => JSON::Any.new(ProcedureConstants::REQUEST_PROCEDURE_REF), "cue" => JSON::Any.new(match[0].downcase)},
          )
        end
        rows
      end
    end
  end

  Extractors.register_annotation_extractor(Extractors::RequestRuleExtractorV1.new)

  # A stable shape identity for one evidence datum (source_category,
  # media_type, and the normalized_metadata shape fields).
  def self.shape_fingerprint(evidence_data : Hash(String, JSON::Any)) : String
    metadata = evidence_data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
    material = {
      "source_category"       => evidence_data["source_category"]? || JSON::Any.new(nil),
      "media_type"            => evidence_data["media_type"]? || JSON::Any.new(nil),
      "interpretation_family" => metadata["interpretation_family"]? || JSON::Any.new(nil),
      "direction"             => metadata["direction"]? || JSON::Any.new(nil),
      "message_kind"          => metadata["message_kind"]? || JSON::Any.new(nil),
      "injection"             => JSON::Any.new(!(metadata["injection_flags"]?.try(&.as_a) || [] of JSON::Any).empty?),
      "shape_version"         => metadata["shape_version"]? || JSON::Any.new("unknown"),
    }
    canonical = JSON.build do |json|
      json.object do
        material.to_a.sort_by(&.[0]).each { |key, value| json.field key, value }
      end
    end
    Digest::SHA256.hexdigest(canonical)
  end

  def self._reference_annotations(reader : Chronicle::GraphProjection, evidence_id : String, facet : String, reference_ref : String) : Array(Chronicle::GraphObject)
    extractor_id, version = _parse_extractor_ref(reference_ref)
    reader.objects(type: "semantic_annotation").select do |obj|
      data = JSON.parse(obj.data)
      data["evidence_id"]?.try(&.as_s?) == evidence_id &&
        data["facet"]?.try(&.as_s?) == facet &&
        data["extractor_id"]?.try(&.as_s?) == extractor_id &&
        data["extractor_version"]?.try(&.as_s?) == version &&
        data["status"]?.try(&.as_s?) == "active"
    end
  end

  def self._accepted_corrections(reader : Chronicle::GraphProjection, annotation_ids : Set(String)) : {Array(String), Array(String), Set(String)}
    accepted = [] of String
    rejected = [] of String
    accepted_subjects = Set(String).new
    reader.objects(type: "evaluation").each do |obj|
      data = JSON.parse(obj.data).as_h
      next unless data["subject_type"]?.try(&.as_s?) == "semantic_annotation"

      subject_id = data["subject_id"]?.try(&.as_s?) || ""
      next unless annotation_ids.includes?(subject_id)

      judgment = data["judgment"]?.try(&.as_s?) || ""
      if judgment.in?({"accepted", "completed_successfully", "correct"})
        accepted << obj.id
        accepted_subjects << subject_id
      elsif judgment.in?({"rejected", "needs_revision", "incorrect"})
        rejected << obj.id
      end
    end
    {accepted, rejected, accepted_subjects}
  end

  # Declare a candidate only after reference annotations were reviewed.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream synthesis
  def self.synthesize_request_procedure_fn(graph : Chronicle::GraphProjection, witness_evidence_ids : Array(String), held_out_evidence_ids : Array(String), counterexample_evidence_ids : Array(String), created_by : String, reference_ref : String = ProcedureConstants::REFERENCE_REF) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("procedure synthesis requires at least three witnesses") if witness_evidence_ids.size < 3
    raise Chronicle::Packs::PackError.new("procedure synthesis requires at least two held-out examples") if held_out_evidence_ids.size < 2
    raise Chronicle::Packs::PackError.new("procedure synthesis requires a counterexample set") if counterexample_evidence_ids.empty?
    raise Chronicle::Packs::PackError.new("procedure synthesis requires a named author") if created_by.empty?

    all_positive = (witness_evidence_ids + held_out_evidence_ids).uniq
    evidence = {} of String => Chronicle::GraphObject
    (all_positive + counterexample_evidence_ids).each do |evidence_id|
      obj = graph.get_object(evidence_id)
      raise Chronicle::Packs::PackError.new("no activity_evidence #{evidence_id.inspect}") if obj.nil? || obj.type != "activity_evidence"

      evidence[evidence_id] = obj
    end
    reference_annotations = [] of Chronicle::GraphObject
    all_positive.each do |evidence_id|
      rows = _reference_annotations(graph, evidence_id, facet: "relation_mention", reference_ref: reference_ref)
      raise Chronicle::Packs::PackError.new("positive example #{evidence_id.inspect} has no reference annotation") if rows.empty?

      reference_annotations.concat(rows)
    end
    annotation_ids = reference_annotations.map(&.id).to_set
    accepted, rejected, accepted_subjects = _accepted_corrections(graph, annotation_ids)
    raise Chronicle::Packs::PackError.new("reference set contains rejected/corrected annotations") if !rejected.empty?
    raise Chronicle::Packs::PackError.new("every reference annotation requires an accepted evaluation") unless (annotation_ids - accepted_subjects).empty?

    fingerprints = witness_evidence_ids.map { |evidence_id| shape_fingerprint(JSON.parse(evidence[evidence_id].data).as_h) }.to_set.to_a.sort
    revision_ids = all_positive.map { |evidence_id| JSON.parse(evidence[evidence_id].data)["revision_id"]?.try(&.as_s?) || "" }.sort!
    identity = stable_id("procedure_candidate", ProcedureConstants::REQUEST_PROCEDURE_REF, reference_ref, revision_ids.join(","))
    existing = graph.objects(type: "procedure_candidate").find { |obj| JSON.parse(obj.data)["candidate_identity"]?.try(&.as_s?) == identity }
    if existing
      return {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(false), "candidate_id" => JSON::Any.new(existing.id), "guard_id" => JSON.parse(existing.data)["guard_id"]? || JSON::Any.new("")}
    end

    guard = graph.add_object("procedure_guard", JSON.build do |json|
      json.object do
        json.field "guard_identity", stable_id("procedure_guard", ProcedureConstants::REQUEST_PROCEDURE_REF, fingerprints.join(","))
        json.field "guard_kind", "shape_and_cue"
        json.field "source_category", "communication"
        json.field "facet", "relation_mention"
        json.field "shape_fingerprints", JSON::Any.new(fingerprints.map { |fingerprint| JSON::Any.new(fingerprint) })
        json.field "cue_pattern_id", "communication.explicit_request@1"
        json.field "max_content_chars", 2_000
        json.field "false_admissions", 0
        json.field "abstentions", 0
        json.field "calibration_examples", all_positive.size + counterexample_evidence_ids.size
        json.field "metadata", JSON::Any.new({"policy_id" => JSON::Any.new(ProcedureConstants::POLICY_ID)})
      end
    end)

    candidate = graph.add_object("procedure_candidate", JSON.build do |json|
      json.object do
        json.field "candidate_identity", identity
        json.field "domain", "semantic_extraction"
        json.field "procedure_kind", "deterministic_parser"
        json.field "candidate_ref", ProcedureConstants::REQUEST_PROCEDURE_REF
        json.field "reference_ref", reference_ref
        json.field "facet", "relation_mention"
        json.field "semantic_objective", "extract explicit inbound communication requests"
        json.field "equivalence_rule", "facet_exact_selector"
        json.field "input_schema", JSON::Any.new({"type" => JSON::Any.new("activity_evidence"), "source_category" => JSON::Any.new("communication")})
        json.field "output_schema", JSON::Any.new({"type" => JSON::Any.new("semantic_annotation"), "facet" => JSON::Any.new("relation_mention")})
        json.field "allowed_effects", JSON::Any.new(["semantic_annotation.create", "extraction_run.create"].map { |e| JSON::Any.new(e) })
        json.field "required_capabilities", JSON::Any.new([] of JSON::Any)
        json.field "action_class", "R0"
        json.field "resource_bounds", JSON::Any.new({"provider_calls" => JSON::Any.new(0), "max_content_chars" => JSON::Any.new(2_000), "max_annotations" => JSON::Any.new(6)})
        json.field "witness_evidence_ids", JSON::Any.new(witness_evidence_ids.map { |id| JSON::Any.new(id) })
        json.field "held_out_evidence_ids", JSON::Any.new(held_out_evidence_ids.map { |id| JSON::Any.new(id) })
        json.field "counterexample_evidence_ids", JSON::Any.new(counterexample_evidence_ids.map { |id| JSON::Any.new(id) })
        json.field "reference_annotation_ids", JSON::Any.new(annotation_ids.to_a.sort.map { |id| JSON::Any.new(id) })
        json.field "correction_evaluation_ids", JSON::Any.new(accepted.sort.map { |id| JSON::Any.new(id) })
        json.field "guard_id", guard.id
        json.field "fallback_ref", reference_ref
        json.field "status", "candidate"
        json.field "status_reason", "awaiting held-out evaluation"
        json.field "created_by", created_by
        json.field "metadata", JSON::Any.new({"policy_id" => JSON::Any.new(ProcedureConstants::POLICY_ID), "drift_deopt_threshold" => JSON::Any.new(3)})
      end
    end)
    graph.add_relation(candidate.id, guard.id, "procedure_has_guard")
    {"ok" => JSON::Any.new(true), "created" => JSON::Any.new(true), "candidate_id" => JSON::Any.new(candidate.id), "guard_id" => JSON::Any.new(guard.id)}
  end

  # (facet, start, end, exact) — the facet_exact_selector equivalence keys.
  def self._selector_keys(rows : Array(Chronicle::GraphObject)) : Set({String, Int32, Int32, String})
    rows.map do |row|
      data = JSON.parse(row.data).as_h
      selector = data["selector"]?.try(&.as_h) || {} of String => JSON::Any
      {data["facet"]?.try(&.as_s?) || "", selector["start"]?.try(&.as_i?) || 0, selector["end"]?.try(&.as_i?) || 0, selector["exact"]?.try(&.as_s?) || ""}
    end.to_set
  end

  def self.guard_admits(guard_data : Hash(String, JSON::Any), evidence_data : Hash(String, JSON::Any)) : {Bool, String}
    if evidence_data["source_category"]?.try(&.as_s?) != guard_data["source_category"]?.try(&.as_s?)
      return {false, "outside_domain"}
    end
    content = evidence_data["normalized_content"]?.try(&.as_s?) || ""
    fingerprint = shape_fingerprint(evidence_data)
    allowed = (guard_data["shape_fingerprints"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).to_set
    unless allowed.includes?(fingerprint)
      return {false, "shape_drift"}
    end
    if content.size > (guard_data["max_content_chars"]?.try(&.as_i?) || 0)
      return {false, "shape_drift"}
    end
    if ProcedureConstants::REQUEST_CUE.match(content).nil?
      return {false, "guard_abstained"}
    end
    {true, "admitted"}
  end

  def self._evaluate_set(reader : Chronicle::GraphProjection, candidate : Chronicle::GraphObject, guard : Chronicle::GraphObject, evidence_ids : Array(String)) : Hash(String, JSON::Any)
    candidate_data = JSON.parse(candidate.data).as_h
    guard_data = JSON.parse(guard.data).as_h
    extractor = Extractors::RequestRuleExtractorV1.new
    matched = 0
    total = 0
    mismatches = 0
    abstentions = 0
    failures = [] of Hash(String, JSON::Any)
    evidence_ids.each do |evidence_id|
      evidence = reader.get_object(evidence_id)
      reference = _reference_annotations(reader, evidence_id, facet: candidate_data["facet"]?.try(&.as_s?) || "", reference_ref: candidate_data["reference_ref"]?.try(&.as_s?) || "")
      expected = _selector_keys(reference)
      evidence_data = evidence ? JSON.parse(evidence.data).as_h : ({} of String => JSON::Any)
      admitted, reason = guard_admits(guard_data, evidence_data)
      actual = if !admitted
                 abstentions += 1
                 Set({String, Int32, Int32, String}).new
               else
                 extractor.extract(evidence_data["normalized_content"]?.try(&.as_s?) || "", evidence_data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any, [candidate_data["facet"]?.try(&.as_s?) || ""]).map { |draft| {draft.facet, draft.start, draft.end, draft.exact} }.to_set
               end
      total += Math.max(1, (expected | actual).size)
      matched += (expected & actual).size
      mismatches += (expected ^ actual).size
      if expected != actual
        failures << {"evidence_id" => JSON::Any.new(evidence_id), "guard" => JSON::Any.new(reason), "expected" => JSON::Any.new(expected.size), "actual" => JSON::Any.new(actual.size)}
      end
    end
    parity = total == 0 ? 1_000 : (matched * 1_000) // total
    {"parity_milli" => JSON::Any.new(parity), "selector_mismatches" => JSON::Any.new(mismatches), "guard_abstentions" => JSON::Any.new(abstentions), "failures" => JSON::Any.new(failures.map { |failure| JSON::Any.new(failure) })}
  end

  # Graph-only evaluation remains the pure/test seam. Runtime callers use the
  # overload below, which performs the vendor-required persisted fork.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream fork evaluation
  def self.evaluate_request_procedure_fn(graph : Chronicle::GraphProjection, candidate_id : String) : Hash(String, JSON::Any)
    candidate = graph.get_object(candidate_id)
    raise Chronicle::Packs::PackError.new("no procedure_candidate #{candidate_id.inspect}") if candidate.nil? || candidate.type != "procedure_candidate"

    candidate_data = JSON.parse(candidate.data).as_h
    unless candidate_data["status"]?.try(&.as_s?) == "candidate"
      raise Chronicle::Packs::PackError.new("procedure evaluation requires candidate status")
    end
    guard = candidate_data["guard_id"]?.try(&.as_s?).try { |guard_id| graph.get_object(guard_id) }
    raise Chronicle::Packs::PackError.new("procedure guard is missing") if guard.nil?

    tip = graph.events.size.to_s
    witness_ids = (candidate_data["witness_evidence_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    held_ids = (candidate_data["held_out_evidence_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    counter_ids = (candidate_data["counterexample_evidence_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    witness = _evaluate_set(graph, candidate, guard, witness_ids)
    heldout = _evaluate_set(graph, candidate, guard, held_ids)
    counter = _evaluate_set(graph, candidate, guard, counter_ids)

    counter_failures = (counter["failures"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h)
    positive_failures = ((witness["failures"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h) + (heldout["failures"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h))
    false_admissions = counter_failures.count { |row| (row["actual"]?.try(&.as_i?) || 0) > 0 && (row["expected"]?.try(&.as_i?) || 0) == 0 }
    false_rejections = positive_failures.count { |row| (row["expected"]?.try(&.as_i?) || 0) > 0 && (row["actual"]?.try(&.as_i?) || 0) == 0 }
    failures = ((witness["failures"]?.try(&.as_a) || [] of JSON::Any) + (heldout["failures"]?.try(&.as_a) || [] of JSON::Any) + (counter["failures"]?.try(&.as_a) || [] of JSON::Any)).map(&.as_h)
    verdict = if witness["parity_milli"]?.try(&.as_i?) == 1_000 &&
                 heldout["parity_milli"]?.try(&.as_i?) == 1_000 &&
                 false_admissions == 0 && false_rejections == 0 &&
                 (counter["selector_mismatches"]?.try(&.as_i?) || 0) == 0
                "pass"
              else
                "fail"
              end

    evaluation_obj = graph.add_object("procedure_evaluation", JSON.build do |json|
      json.object do
        json.field "evaluation_identity", stable_id("procedure_evaluation", candidate_id, "graph", tip)
        json.field "candidate_id", candidate_id
        json.field "fork_run_id", "graph"
        json.field "forked_at_event_id", tip
        json.field "witness_count", witness_ids.size
        json.field "held_out_count", held_ids.size
        json.field "counterexample_count", counter_ids.size
        json.field "witness_parity_milli", witness["parity_milli"]?.try(&.as_i?) || 0
        json.field "held_out_parity_milli", heldout["parity_milli"]?.try(&.as_i?) || 0
        json.field "false_admissions", false_admissions
        json.field "false_rejections", false_rejections
        json.field "selector_mismatches", ((witness["selector_mismatches"]?.try(&.as_i?) || 0) + (heldout["selector_mismatches"]?.try(&.as_i?) || 0) + (counter["selector_mismatches"]?.try(&.as_i?) || 0))
        json.field "guard_abstentions", ((witness["guard_abstentions"]?.try(&.as_i?) || 0) + (heldout["guard_abstentions"]?.try(&.as_i?) || 0) + (counter["guard_abstentions"]?.try(&.as_i?) || 0))
        json.field "candidate_calls", (witness_ids.size + held_ids.size + counter_ids.size) - (counter["guard_abstentions"]?.try(&.as_i?) || 0)
        json.field "reference_calls", 0
        json.field "verdict", verdict
        json.field "failures", JSON::Any.new(failures.map { |failure| JSON::Any.new(failure) })
        json.field "evidence_refs", JSON::Any.new((witness_ids + held_ids + counter_ids).map { |id| JSON::Any.new(id) })
        json.field "correction_evaluation_ids", JSON::Any.new((candidate_data["correction_evaluation_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).map { |id| JSON::Any.new(id) })
        json.field "promote_marker_event_id", JSON::Any.new(nil)
        json.field "metadata", JSON::Any.new({"policy_id" => JSON::Any.new(ProcedureConstants::POLICY_ID), "equivalence" => JSON::Any.new("facet_exact_selector"), "candidate_provider_calls" => JSON::Any.new(0), "reference_outputs" => JSON::Any.new("recorded")})
      end
    end)
    graph.add_relation(candidate_id, evaluation_obj.id, "procedure_evaluated_by")

    candidate_merged = candidate_data.dup
    candidate_merged["status"] = JSON::Any.new(verdict == "pass" ? "evaluated" : "demoted")
    candidate_merged["status_reason"] = JSON::Any.new("evaluation #{verdict}")
    graph.patch_object(candidate_id, JSON::Any.new(candidate_merged).to_json)

    {"ok" => JSON::Any.new(verdict == "pass"), "evaluation_id" => JSON::Any.new(evaluation_obj.id), "verdict" => JSON::Any.new(verdict), "fork_run_id" => JSON::Any.new("graph"), "promote_marker_event_id" => JSON::Any.new(nil)}
  end

  # Evaluate in a real persisted fork, then promote only the fork's audited
  # candidate/evaluation delta. This mirrors vendor
  # evaluate_request_procedure_fn: the parent never labels a direct-graph
  # trial as a fork, and a failed promotion is an explicit error rather than
  # silently retaining an unreviewable evaluation.
  def self.evaluate_request_procedure_fn(runtime : Chronicle::Runtime(M), candidate_id : String) : Hash(String, JSON::Any) forall M
    parent_graph = runtime.graph || raise Chronicle::Packs::PackError.new("procedure evaluation requires an attached runtime graph")
    candidate = parent_graph.get_object(candidate_id)
    raise Chronicle::Packs::PackError.new("no procedure_candidate #{candidate_id.inspect}") if candidate.nil? || candidate.type != "procedure_candidate"
    raise Chronicle::Packs::PackError.new("procedure evaluation requires candidate status") unless JSON.parse(candidate.data)["status"]?.try(&.as_s?) == "candidate"

    anchor = parent_graph.events.last?.try(&.id)
    raise Chronicle::Packs::PackError.new("procedure evaluation requires a persisted event at which to fork") if anchor.nil?
    fork = runtime.fork(anchor, label: "procedure-eval:#{candidate_id}")
    fork_graph = fork.graph || raise Chronicle::Packs::PackError.new("procedure evaluation fork has no graph")
    evaluated = evaluate_request_procedure_fn(fork_graph, candidate_id)
    evaluation_id = evaluated["evaluation_id"].as_s
    evaluation = fork_graph.get_object(evaluation_id) || raise Chronicle::Packs::PackError.new("forked procedure evaluation was not persisted")
    evaluation_data = JSON.parse(evaluation.data).as_h
    evaluation_data["evaluation_identity"] = JSON::Any.new(stable_id("procedure_evaluation", candidate_id, fork.run_id, anchor))
    evaluation_data["fork_run_id"] = JSON::Any.new(fork.run_id)
    evaluation_data["forked_at_event_id"] = JSON::Any.new(anchor)
    fork_graph.patch_object(evaluation_id, JSON::Any.new(evaluation_data).to_json)

    plan = runtime.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    unless plan.is_promotable
      raise Chronicle::Packs::PackError.new("procedure evaluation promotion conflict: #{plan.conflicts.join(", ")}")
    end
    promoted = runtime.promote(fork).as(Chronicle::PromoteResult)
    parent_evaluation = parent_graph.get_object(evaluation_id) || raise Chronicle::Packs::PackError.new("promoted procedure evaluation is missing")
    promoted_data = JSON.parse(parent_evaluation.data).as_h
    promoted_data["promote_marker_event_id"] = JSON::Any.new(promoted.marker_event_id)
    parent_graph.patch_object(evaluation_id, JSON::Any.new(promoted_data).to_json)

    {
      "ok"                      => evaluated["ok"]? || JSON::Any.new(false),
      "evaluation_id"           => JSON::Any.new(evaluation_id),
      "verdict"                 => evaluated["verdict"]? || JSON::Any.new("fail"),
      "fork_run_id"             => JSON::Any.new(fork.run_id),
      "promote_marker_event_id" => JSON::Any.new(promoted.marker_event_id),
    }
  end

  # Promote a passing candidate — approver-gated, supersedes prior promoted
  # procedures for the same domain+facet.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream promotion gates
  def self.promote_request_procedure_fn(graph : Chronicle::GraphProjection, candidate_id : String, evaluation_id : String, approver : String) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("procedure promotion requires a named approver") if approver.empty?

    candidate = graph.get_object(candidate_id)
    evaluation = graph.get_object(evaluation_id)
    raise Chronicle::Packs::PackError.new("procedure candidate is missing") if candidate.nil? || candidate.type != "procedure_candidate"
    raise Chronicle::Packs::PackError.new("procedure evaluation is missing") if evaluation.nil? || evaluation.type != "procedure_evaluation"

    evaluation_data = JSON.parse(evaluation.data).as_h
    unless evaluation_data["candidate_id"]?.try(&.as_s?) == candidate_id && evaluation_data["verdict"]?.try(&.as_s?) == "pass"
      raise Chronicle::Packs::PackError.new("procedure promotion requires its own passing evaluation")
    end
    if (evaluation_data["held_out_parity_milli"]?.try(&.as_i?) || 0) != 1_000 || (evaluation_data["false_admissions"]?.try(&.as_i?) || 0) != 0 || (evaluation_data["false_rejections"]?.try(&.as_i?) || 0) != 0
      raise Chronicle::Packs::PackError.new("procedure promotion thresholds are not met")
    end

    candidate_data = JSON.parse(candidate.data).as_h
    graph.objects(type: "procedure_candidate").each do |prior|
      prior_data = JSON.parse(prior.data).as_h
      next unless prior.id != candidate_id
      next unless prior_data["domain"]?.try(&.as_s?) == candidate_data["domain"]?.try(&.as_s?)
      next unless prior_data["facet"]?.try(&.as_s?) == candidate_data["facet"]?.try(&.as_s?)
      next unless prior_data["status"]?.try(&.as_s?) == "promoted"

      merged = prior_data.dup
      merged["status"] = JSON::Any.new("demoted")
      merged["status_reason"] = JSON::Any.new("superseded by #{candidate_id}")
      graph.patch_object(prior.id, JSON::Any.new(merged).to_json)
    end

    metadata = (candidate_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
    metadata["promotion_evaluation_id"] = JSON::Any.new(evaluation_id)
    metadata["approved_by"] = JSON::Any.new(approver)
    candidate_merged = candidate_data.dup
    candidate_merged["status"] = JSON::Any.new("promoted")
    candidate_merged["status_reason"] = JSON::Any.new("approved by #{approver} citing #{evaluation_id}")
    candidate_merged["metadata"] = JSON::Any.new(metadata)
    graph.patch_object(candidate_id, JSON::Any.new(candidate_merged).to_json)

    graph.add_object("annotation_extractor_state", JSON.build do |json|
      json.object do
        json.field "state_identity", stable_id("annotation_extractor_state", ProcedureConstants::REQUEST_PROCEDURE_REF, "promoted", evaluation_id)
        json.field "extractor_id", "semantic.request_rule"
        json.field "extractor_version", "0.1.0"
        json.field "status", "promoted"
        json.field "reason", "guarded procedure approved by #{approver}"
        json.field "metadata", JSON::Any.new({"procedure_candidate_id" => JSON::Any.new(candidate_id), "evaluation_id" => JSON::Any.new(evaluation_id)})
      end
    end)
    {"ok" => JSON::Any.new(true), "candidate_id" => JSON::Any.new(candidate_id), "procedure_ref" => JSON::Any.new(ProcedureConstants::REQUEST_PROCEDURE_REF)}
  end

  # The promoted candidate (and its guard) covering one facet+evidence, or nil.
  def self.active_procedure_for(reader : Chronicle::GraphProjection, evidence_data : Hash(String, JSON::Any), facet : String) : Hash(String, JSON::Any)?
    candidates = reader.objects(type: "procedure_candidate").select do |obj|
      data = JSON.parse(obj.data)
      data["status"]?.try(&.as_s?) == "promoted" && data["facet"]?.try(&.as_s?) == facet
    end
    return nil if candidates.empty?

    candidates.sort_by! { |obj| JSON.parse(obj.data)["candidate_identity"]?.try(&.as_s?) || "" }
    candidate = candidates.last
    candidate_data = JSON.parse(candidate.data).as_h
    guard = candidate_data["guard_id"]?.try(&.as_s?).try { |guard_id| reader.objects(type: "procedure_guard").find { |obj| obj.id == guard_id } }
    return nil if guard.nil?

    admitted, reason = guard_admits(JSON.parse(guard.data).as_h, evidence_data)
    {"candidate" => JSON::Any.new(candidate.id), "guard" => JSON::Any.new(guard.id), "admitted" => JSON::Any.new(admitted), "reason" => JSON::Any.new(reason)}
  end

  # Record a guard abstention/drift and auto-demote past the drift threshold.
  def self.record_deoptimization(graph : Chronicle::GraphProjection, reader : Chronicle::GraphProjection, candidate : Chronicle::GraphObject, guard : Chronicle::GraphObject, evidence_obj : Chronicle::GraphObject, reason : String) : String?
    return nil if reason == "outside_domain"

    normalized = reason == "shape_drift" ? "shape_drift" : "guard_abstained"
    candidate_data = JSON.parse(candidate.data).as_h
    evidence_data = JSON.parse(evidence_obj.data).as_h
    identity = stable_id("procedure_deoptimization", candidate.id, evidence_data["revision_id"]?.try(&.as_s?) || "", normalized)
    existing = reader.objects(type: "procedure_deoptimization").find { |obj| JSON.parse(obj.data)["deoptimization_identity"]?.try(&.as_s?) == identity }
    return existing.id if existing

    prior = reader.objects(type: "procedure_deoptimization").select { |obj| JSON.parse(obj.data)["candidate_id"]?.try(&.as_s?) == candidate.id && JSON.parse(obj.data)["reason"]?.try(&.as_s?) == "shape_drift" }
    deopt = graph.add_object("procedure_deoptimization", JSON.build do |json|
      json.object do
        json.field "deoptimization_identity", identity
        json.field "candidate_id", candidate.id
        json.field "evidence_id", evidence_obj.id
        json.field "reason", normalized
        json.field "guard_id", guard.id
        json.field "fallback_ref", candidate_data["fallback_ref"]?.try(&.as_s?) || ""
        json.field "fallback_status", "requested"
        json.field "fallback_run_ids", JSON::Any.new([] of JSON::Any)
        json.field "input_fingerprint", shape_fingerprint(evidence_data)
        json.field "evidence_refs", JSON::Any.new([evidence_obj.id].map { |id| JSON::Any.new(id) })
        json.field "metadata", JSON::Any.new({"policy_id" => JSON::Any.new(ProcedureConstants::POLICY_ID)})
      end
    end)
    graph.add_relation(candidate.id, deopt.id, "procedure_deoptimized_by")
    threshold = (candidate_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["drift_deopt_threshold"]?.try(&.as_i?) || 3
    if normalized == "shape_drift" && prior.size + 1 >= threshold
      merged = candidate_data.dup
      merged["status"] = JSON::Any.new("demoted")
      merged["status_reason"] = JSON::Any.new("demoted after #{threshold} shape-drift deoptimizations")
      graph.patch_object(candidate.id, JSON::Any.new(merged).to_json)
    end
    deopt.id
  end
end

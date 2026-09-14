require "json"

module Chronicle::Packs::SemanticExtraction
  # Semantic Extraction tools. Ported from upstream
  # packs/semantic_extraction/tools.py (slice 1: extract_annotations,
  # annotation_coverage). Profile updates, extractor trials, LLM promotion,
  # and procedure synthesis are deferred.

  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Extract annotations from one evidence revision through the profile policy.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful aggregation of the upstream multi-extractor response
  def self.extract_annotations_fn(graph : Chronicle::GraphProjection, evidence_id : String, settings : SemanticExtractionSettings, requested_facets : Array(String)? = nil) : Hash(String, JSON::Any)
    evidence_obj = graph.get_object(evidence_id)
    raise Chronicle::Packs::PackError.new("unknown activity_evidence: #{evidence_id}") if evidence_obj.nil? || evidence_obj.type != "activity_evidence"

    results = run_profile_extraction(graph, evidence_obj, settings: settings, requested_facets: requested_facets)
    return {"ok" => JSON::Any.new(false)} if results.empty?

    runs = results.compact_map do |result|
      graph.get_object(result["run"]?.try(&.as_s?) || "")
    end
    return {"ok" => JSON::Any.new(false)} if runs.empty?

    run_data = runs.map { |run| {run, JSON.parse(run.data).as_h} }
    executed = run_data.flat_map { |_run, data| data["executed_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String }.to_set.to_a.sort
    cached = run_data.flat_map { |_run, data| data["cached_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String }.to_set.to_a.sort
    annotation_ids = run_data.flat_map { |_run, data| data["annotation_ids"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String }
    first, first_data = run_data.first
    runs_json = run_data.map do |run, data|
      JSON::Any.new({
        "run_id"            => JSON::Any.new(run.id),
        "run_identity"      => data["run_identity"]? || JSON::Any.new(nil),
        "extractor_id"      => data["extractor_id"]? || JSON::Any.new(nil),
        "extractor_version" => data["extractor_version"]? || JSON::Any.new(nil),
        "executed_facets"   => data["executed_facets"]? || JSON::Any.new([] of JSON::Any),
        "cached_facets"     => data["cached_facets"]? || JSON::Any.new([] of JSON::Any),
      })
    end
    {
      "ok"              => JSON::Any.new(results.all? { |result| result["ok"]?.try(&.as_bool?) || false }),
      "created"         => JSON::Any.new(results.any? { |result| result["created"]?.try(&.as_bool?) || false }),
      "run"             => JSON::Any.new(first.id),
      "run_id"          => JSON::Any.new(first.id),
      "run_identity"    => first_data["run_identity"]? || JSON::Any.new(nil),
      "executed_facets" => JSON::Any.new(executed.map { |facet| JSON::Any.new(facet) }),
      "cached_facets"   => JSON::Any.new(cached.map { |facet| JSON::Any.new(facet) }),
      "annotation_ids"  => JSON::Any.new(annotation_ids.map { |id| JSON::Any.new(id) }),
      "runs"            => JSON::Any.new(runs_json),
    }
  end

  # Fork-trial the candidate extractor against the baseline (ADR 0014).
  # Drafts only — no annotations materialized, no policy changes. The
  # per-facet comparison lands as extractor_promotion_evidence.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream trial verdict
  def self.run_extractor_trial_fn(graph : Chronicle::GraphProjection, evidence_ids : Array(String), candidate_ref : String = "semantic.llm@0.1.0", baseline_ref : String = "semantic.deterministic@0.1.0", facets : Array(String)? = nil, settings : SemanticExtractionSettings? = nil, created_by : String = "owner") : Hash(String, JSON::Any)
    candidate = Extractors.get_annotation_extractor(*_parse_extractor_ref(candidate_ref))
    baseline = Extractors.get_annotation_extractor(*_parse_extractor_ref(baseline_ref))
    trial_facets = (facets || candidate.implemented_facets).to_set.to_a.sort
    trial_facets.each do |facet|
      raise Chronicle::Packs::PackError.new("unknown facet #{facet.inspect}") unless Facet.parse?(facet) || facet.includes?(".")
    end

    evidence_objs = [] of Chronicle::GraphObject
    evidence_ids.each do |evidence_id|
      obj = graph.get_object(evidence_id)
      raise Chronicle::Packs::PackError.new("no activity_evidence with id #{evidence_id.inspect}") if obj.nil? || obj.type != "activity_evidence"

      evidence_objs << obj
    end
    raise Chronicle::Packs::PackError.new("an extractor trial needs at least one evidence id") if evidence_objs.empty?

    comparison = {} of String => Hash(String, Int32)
    trial_facets.each { |facet| comparison[facet] = {"baseline" => 0, "candidate" => 0, "candidate_only" => 0, "baseline_only" => 0} }
    evidence_objs.each do |obj|
      evidence_data = JSON.parse(obj.data).as_h
      content = evidence_data["normalized_content"]?.try(&.as_s?) || ""
      metadata = evidence_data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any
      baseline_keys = _trial_keys(baseline.extract(content, metadata, trial_facets))
      candidate_keys = _trial_keys(candidate.extract(content, metadata, trial_facets))
      trial_facets.each do |facet|
        base_f = baseline_keys.select { |key| key[0] == facet }.to_set
        cand_f = candidate_keys.select { |key| key[0] == facet }.to_set
        entry = comparison[facet]
        entry["baseline"] += base_f.size
        entry["candidate"] += cand_f.size
        entry["candidate_only"] += (cand_f - base_f).size
        entry["baseline_only"] += (base_f - cand_f).size
      end
    end

    facet_gains = comparison.values.count { |entry| entry["candidate"] > 0 && entry["baseline"] == 0 }
    facet_losses = comparison.values.count { |entry| entry["baseline"] > 0 && entry["candidate"] == 0 }
    verdict = if facet_gains > facet_losses
                "candidate_richer"
              elsif facet_losses > facet_gains
                "baseline_richer"
              else
                "neutral"
              end

    candidate_id, candidate_version = _parse_extractor_ref(candidate_ref)
    baseline_id, baseline_version = _parse_extractor_ref(baseline_ref)
    revision_ids = evidence_objs.map { |obj| JSON.parse(obj.data)["revision_id"]?.try(&.as_s?) || "" }.sort!
    evidence = graph.add_object("extractor_promotion_evidence", JSON.build do |json|
      json.object do
        json.field "evidence_identity", stable_id("extractor_trial", candidate_ref, baseline_ref, revision_ids.join(","), trial_facets.join(","))
        json.field "candidate_extractor_id", candidate_id
        json.field "candidate_extractor_version", candidate_version
        json.field "baseline_extractor_id", baseline_id
        json.field "baseline_extractor_version", baseline_version
        json.field "evidence_ids", JSON::Any.new(evidence_objs.map { |obj| JSON::Any.new(obj.id) })
        json.field "facets", JSON::Any.new(trial_facets.map { |facet| JSON::Any.new(facet) })
        json.field "comparison", JSON::Any.new(comparison.transform_values { |entry| JSON::Any.new(entry.transform_values { |count| JSON::Any.new(count) }) })
        json.field "verdict", verdict
        json.field "rationale", "recorded-content trial: candidate vs baseline drafts, keyed by (facet, start, end, exact)"
        json.field "created_by", created_by
        json.field "metadata", JSON::Any.new({"candidate_config" => JSON::Any.new(candidate.config), "baseline_config" => JSON::Any.new(baseline.config)})
      end
    end)
    {"ok" => JSON::Any.new(true), "evidence_id" => JSON::Any.new(evidence.id), "verdict" => JSON::Any.new(verdict), "comparison" => JSON::Any.new(comparison.transform_values { |entry| JSON::Any.new(entry.transform_values { |count| JSON::Any.new(count) }) })}
  end

  private def self._trial_keys(drafts : Array(AnnotationDraft)) : Set({String, Int32, Int32, String})
    drafts.map { |draft| {draft.facet, draft.start, draft.end, draft.exact} }.to_set
  end

  # Promote the candidate extractor citing recorded trial evidence (ADR
  # 0014): flips the extractor state to promoted and routes the covered
  # facets to it in the next profile version.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream promotion
  def self.promote_llm_extractor_fn(graph : Chronicle::GraphProjection, promotion_evidence_id : String, approver : String, facets : Array(String)? = nil) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("promotion requires an explicit approver") if approver.empty?

    evidence = graph.get_object(promotion_evidence_id)
    raise Chronicle::Packs::PackError.new("no extractor_promotion_evidence with id #{promotion_evidence_id.inspect}") if evidence.nil? || evidence.type != "extractor_promotion_evidence"

    evidence_data = JSON.parse(evidence.data).as_h
    ref = "#{evidence_data["candidate_extractor_id"]?.try(&.as_s?) || ""}@#{evidence_data["candidate_extractor_version"]?.try(&.as_s?) || ""}"
    routed = (facets || (evidence_data["facets"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)).sort
    raise Chronicle::Packs::PackError.new("nothing to route: the trial covered no facets") if routed.empty?

    graph.add_object("annotation_extractor_state", JSON.build do |json|
      json.object do
        json.field "state_identity", stable_id("annotation_extractor_state", ref, "promoted", promotion_evidence_id)
        json.field "extractor_id", evidence_data["candidate_extractor_id"]?.try(&.as_s?) || ""
        json.field "extractor_version", evidence_data["candidate_extractor_version"]?.try(&.as_s?) || ""
        json.field "status", "promoted"
        json.field "reason", "promoted by #{approver} citing #{promotion_evidence_id}"
        json.field "metadata", JSON::Any.new({"promotion_evidence_id" => JSON::Any.new(promotion_evidence_id)})
      end
    end)

    current = graph.objects(type: "extraction_profile").sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }.reverse.find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    merged = (current ? (JSON.parse(current.data)["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any) : {} of String => JSON::Any).transform_values(&.as_s)
    routed.each { |facet| merged[facet] = ref }
    profile = update_extraction_profile_fn(
      graph,
      extractor_by_facet: merged,
      rationale: "promote #{ref} for #{routed.join(", ")} (evidence #{promotion_evidence_id}, approved by #{approver})",
      created_by: approver,
    )
    {"ok" => JSON::Any.new(true), "extractor_ref" => JSON::Any.new(ref), "routed_facets" => JSON::Any.new(routed.map { |facet| JSON::Any.new(facet) })}.merge(profile)
  end

  # Add the model-only facets to the active extraction policy. Provider
  # configuration and graph policy are deliberately separate: enabling a
  # provider mints a new policy version rather than leaving the key unused.
  def self.ensure_llm_extraction_profile_fn(graph : Chronicle::GraphProjection, actor : String) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("LLM profile activation requires a named actor") if actor.empty?

    profiles = graph.objects(type: "extraction_profile").sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }
    current = profiles.reverse.find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    return {"ok" => JSON::Any.new(false), "profile_updated" => JSON::Any.new(false), "reason" => JSON::Any.new("profile_missing")} if current.nil?

    current_data = JSON.parse(current.data).as_h
    extractor_by_facet = (current_data["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any).transform_values(&.as_s)
    ref = "semantic.llm@0.1.0"
    already_active = Facets::LLM_UPGRADE_FACETS.all? { |facet| extractor_by_facet[facet.to_s]? == ref }
    if already_active
      return {"ok" => JSON::Any.new(true), "profile_updated" => JSON::Any.new(false), "profile_id" => JSON::Any.new(current.id), "version" => current_data["version"]? || JSON::Any.new(0)}
    end

    Facets::LLM_UPGRADE_FACETS.each { |facet| extractor_by_facet[facet.to_s] = ref }
    default_facets = ((current_data["default_facets"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).to_set + Facets::LLM_UPGRADE_FACETS.to_set).to_a.sort
    llm_state_exists = graph.objects(type: "annotation_extractor_state").any? do |obj|
      data = JSON.parse(obj.data)
      data["extractor_id"]?.try(&.as_s?) == "semantic.llm" &&
        data["extractor_version"]?.try(&.as_s?) == "0.1.0" &&
        data["status"]?.try(&.as_s?).in?({"candidate", "promoted"})
    end
    unless llm_state_exists
      graph.add_object("annotation_extractor_state", JSON.build do |json|
        json.object do
          json.field "state_identity", stable_id("annotation_extractor_state", "semantic.llm", "0.1.0", "candidate")
          json.field "extractor_id", "semantic.llm"
          json.field "extractor_version", "0.1.0"
          json.field "status", "candidate"
          json.field "reason", "provider configured; model-only facets enabled"
          json.field "metadata", JSON::Any.new({} of String => JSON::Any)
        end
      end)
    end
    result = update_extraction_profile_fn(
      graph,
      default_facets: default_facets,
      extractor_by_facet: extractor_by_facet,
      rationale: "enable relation_mention/event_mention through semantic.llm after an explicit provider configuration (D025 stage two)",
      created_by: actor,
    )
    result["profile_updated"] = JSON::Any.new(true)
    result
  end

  # Read the coverage record for one extraction run.
  def self.annotation_coverage_fn(graph : Chronicle::GraphProjection, run_id : String) : JSON::Any?
    coverage = graph.objects(type: "extraction_coverage").find { |obj| JSON.parse(obj.data)["run_id"]?.try(&.as_s?) == run_id }
    coverage ? JSON.parse(coverage.data) : nil
  end

  @[Chronicle::Packs::Annotations::Tool(name: "extract_annotations", description: "Extract typed annotations from an evidence revision through the active extraction profile.", deterministic: true)]
  def extract_annotations_tool(args : String) : String
    input = JSON.parse(args).as_h
    settings = input["settings"]? ? SemanticExtractionSettings.from_json(input["settings"].to_json) : SemanticExtractionSettings.new
    requested = input["requested_facets"]?.try(&.as_a?.try(&.map(&.as_s)))
    result = extract_annotations_fn(bound_graph_or_raise, input["evidence_id"]?.try(&.as_s?) || "", settings, requested_facets: requested)
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "annotation_coverage", description: "Read the extraction coverage record for an extraction run.", deterministic: true)]
  def annotation_coverage_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = annotation_coverage_fn(bound_graph_or_raise, input["run_id"]?.try(&.as_s?) || "")
    result ? result.to_json : "null"
  end

  # Mint the next extraction_profile version; supersede the active one.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream profile versioner
  def self.update_extraction_profile_fn(graph : Chronicle::GraphProjection, default_facets : Array(String)? = nil, facets_by_source_category : Hash(String, Array(String))? = nil, extractor_by_facet : Hash(String, String)? = nil, rationale : String = "", created_by : String = "owner") : Hash(String, JSON::Any)
    (default_facets || [] of String).each { |facet| _validate_facet_ref(facet, nil) }
    (facets_by_source_category || {} of String => Array(String)).values.flatten.each { |facet| _validate_facet_ref(facet, nil) }
    (extractor_by_facet || {} of String => String).each do |facet, ref|
      _validate_facet_ref(facet, ref)
    end

    profiles = graph.objects(type: "extraction_profile").sort_by! { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i) || 0 }
    current = profiles.reverse.find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
    version = profiles.empty? ? 1 : ((JSON.parse(profiles.last.data)["version"]?.try(&.as_i) || 0) + 1)
    base = current ? JSON.parse(current.data).as_h : {} of String => JSON::Any
    new_profile = ExtractionProfile.new(
      stable_id("extraction_profile", version), version,
      (default_facets || (base["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String)).sort,
      created_by,
      facets_by_source_category: facets_by_source_category ? facets_by_source_category.transform_values(&.sort) : (base["facets_by_source_category"]?.try(&.as_h) || {} of String => JSON::Any).transform_values { |v| v.as_a.map(&.as_s) },
      extractor_by_facet: extractor_by_facet ? extractor_by_facet : (base["extractor_by_facet"]?.try(&.as_h) || {} of String => JSON::Any).transform_values(&.as_s),
      rationale: rationale, supersedes_profile_id: current ? current.id : nil,
    )
    profile_obj = graph.add_object("extraction_profile", new_profile.to_json)
    if current
      old = JSON.parse(current.data).as_h
      old["status"] = JSON::Any.new("superseded")
      graph.patch_object(current.id, JSON::Any.new(old).to_json)
    end
    {"ok" => JSON::Any.new(true), "profile_id" => JSON::Any.new(profile_obj.id), "version" => JSON::Any.new(version)}
  end

  def self._validate_facet_ref(facet : String, ref : String?) : Nil
    standard = Facet.parse?(facet) != nil
    raise Chronicle::Packs::PackError.new("unknown facet #{facet.inspect}") unless standard || facet.includes?(".")
    if ref
      parts = ref.split("@")
      if parts.size != 2 || parts[0].empty? || parts[1].empty?
        raise Chronicle::Packs::PackError.new("malformed extractor reference #{ref.inspect}")
      end
    end
  end

  # Disable an extractor version and everything that depends on it.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream invalidation walk
  def self.invalidate_annotation_extractor_fn(graph : Chronicle::GraphProjection, extractor_id : String, extractor_version : String, reason : String) : Hash(String, JSON::Any)
    raise Chronicle::Packs::PackError.new("an invalidation reason is required") if reason.empty?

    graph.add_object("annotation_extractor_state", JSON.build do |json|
      json.object do
        json.field "state_identity", stable_id("annotation_extractor_state", extractor_id, extractor_version, reason)
        json.field "extractor_id", extractor_id
        json.field "extractor_version", extractor_version
        json.field "status", "disabled"
        json.field "reason", reason
      end
    end)

    invalidated_runs = 0
    graph.objects(type: "extraction_run").each do |run|
      data = JSON.parse(run.data).as_h
      if data["extractor_id"]?.try(&.as_s?) == extractor_id && data["extractor_version"]?.try(&.as_s?) == extractor_version && data["status"]?.try(&.as_s?) == "completed"
        old = JSON.parse(run.data).as_h
        old["status"] = JSON::Any.new("invalidated")
        graph.patch_object(run.id, JSON::Any.new(old).to_json)
        invalidated_runs += 1
      end
    end

    invalidated_annotations = 0
    graph.objects(type: "semantic_annotation").each do |annotation_obj|
      data = JSON.parse(annotation_obj.data).as_h
      if data["extractor_id"]?.try(&.as_s?) == extractor_id && data["extractor_version"]?.try(&.as_s?) == extractor_version && data["status"]?.try(&.as_s?) == "active"
        old = JSON.parse(annotation_obj.data).as_h
        old["status"] = JSON::Any.new("invalidated")
        old["invalidation_reason"] = JSON::Any.new(reason)
        graph.patch_object(annotation_obj.id, JSON::Any.new(old).to_json)
        invalidated_annotations += 1
      end
    end

    invalidated_candidates = 0
    ["profile_candidate", "memory_candidate"].each do |candidate_type|
      graph.objects(type: candidate_type).each do |candidate|
        data = JSON.parse(candidate.data).as_h
        metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
        next unless metadata["annotation_identity"]?.try(&.as_s?)
        annotation_object = graph.objects(type: "semantic_annotation").find { |obj| JSON.parse(obj.data)["annotation_identity"]?.try(&.as_s?) == metadata["annotation_identity"].as_s }
        next if annotation_object.nil?

        annotation_data = JSON.parse(annotation_object.data).as_h
        next unless annotation_data["extractor_id"]?.try(&.as_s?) == extractor_id && annotation_data["extractor_version"]?.try(&.as_s?) == extractor_version
        next unless annotation_data["status"]?.try(&.as_s?) == "invalidated"

        old = JSON.parse(candidate.data).as_h
        if candidate_type == "profile_candidate"
          old["status"] = JSON::Any.new("invalidated")
        else
          old["accepted"] = JSON::Any.new(false)
        end
        graph.patch_object(candidate.id, JSON::Any.new(old).to_json)
        invalidated_candidates += 1
      end
    end

    {"ok" => JSON::Any.new(true), "invalidated_runs" => JSON::Any.new(invalidated_runs), "invalidated_annotations" => JSON::Any.new(invalidated_annotations), "invalidated_candidates" => JSON::Any.new(invalidated_candidates)}
  end

  @[Chronicle::Packs::Annotations::Tool(name: "update_extraction_profile", description: "Mint the next extraction_profile version, superseding the active one.", deterministic: true)]
  def update_extraction_profile_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = update_extraction_profile_fn(
      bound_graph_or_raise,
      default_facets: input["default_facets"]?.try(&.as_a?.try(&.map(&.as_s))),
      facets_by_source_category: input["facets_by_source_category"]?.try(&.as_h) ? input["facets_by_source_category"].as_h.transform_values { |v| v.as_a.map(&.as_s) } : nil,
      extractor_by_facet: input["extractor_by_facet"]?.try(&.as_h) ? input["extractor_by_facet"].as_h.transform_values(&.as_s) : nil,
      rationale: input["rationale"]?.try(&.as_s?) || "",
      created_by: input["created_by"]?.try(&.as_s?) || "owner",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "invalidate_annotation_extractor", description: "Disable an extractor version and invalidate its runs, annotations, and dependent candidates.", deterministic: true)]
  def invalidate_annotation_extractor_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = invalidate_annotation_extractor_fn(
      bound_graph_or_raise,
      input["extractor_id"]?.try(&.as_s?) || "", input["extractor_version"]?.try(&.as_s?) || "",
      reason: input["reason"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  # Declare a guarded procedure candidate once its reference annotations were
  # reviewed (three witnesses, two held-out, a counterexample set).
  @[Chronicle::Packs::Annotations::Tool(name: "synthesize_request_procedure", description: "Declare a guarded deterministic request extractor from reviewed reference annotations (three witnesses, two held-out, counterexamples).", deterministic: true)]
  def synthesize_request_procedure_tool(args : String) : String
    input = JSON.parse(args).as_h
    witness = (input["witness_evidence_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    held = (input["held_out_evidence_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    counter = (input["counterexample_evidence_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    result = synthesize_request_procedure_fn(
      bound_graph_or_raise,
      witness_evidence_ids: witness, held_out_evidence_ids: held,
      counterexample_evidence_ids: counter,
      created_by: input["created_by"]?.try(&.as_s?) || "owner",
    )
    result.to_json
  end

  # Promote a guarded procedure only with its passing evaluation and a named
  # approver.
  @[Chronicle::Packs::Annotations::Tool(name: "promote_request_procedure", description: "Promote a guarded deterministic request extractor only with its passing forked evaluation and a named approver.", deterministic: true)]
  def promote_request_procedure_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = promote_request_procedure_fn(
      bound_graph_or_raise,
      input["candidate_id"]?.try(&.as_s?) || "",
      input["evaluation_id"]?.try(&.as_s?) || "",
      approver: input["approver"]?.try(&.as_s?) || "",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "semantic_extraction tools require a bound graph (set SemanticExtraction.bound_graph)"
    )
  end
end

require "json"
require "time"

module Chronicle::Packs::Evolution
  # Evolution Pack authoring and request functions. Ported from upstream
  # packs/evolution/tools.py.
  #
  # `submit_proposal_fn` is the ONE authoring entry point: scripted
  # generators, owner-drafted packs routed through chat, and a future LLM
  # author all pass through it, and everything downstream treats them
  # identically.
  def self._now : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%S%:z")
  end

  # Store a candidate pack as artifacts + a mod_proposal.
  #
  # The bundle hash is pinned HERE, at submission, over the exact bytes
  # submitted (manifest included). With `drafting_context_id`, the injection
  # flags are RECOMPUTED from the objects the record admitted (never from
  # the record's stored field), and the admitted structured fields are
  # charset-validated (refusing submission when prose-shaped).
  def self.submit_proposal_fn(
    graph : Chronicle::GraphProjection,
    *,
    pack_name : String,
    files : Hash(String, String),
    gap_id : String = "",
    pack_version : String = "0.1.0",
    rationale : String = "",
    authored_by : String = "agent",
    drafting_context_id : String = "",
  ) : Chronicle::GraphObject
    inherited_flags = [] of String
    if !drafting_context_id.empty?
      record = graph.get_object(drafting_context_id)
      if record
        record_data = JSON.parse(record.data).as_h
        field_violations = AuthorFrame.validate_structured_fields(graph, (record_data["structured_fields"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s))
        unless field_violations.empty?
          raise PackError.new("drafting record admits non-identifier structured fields; refusing to submit: #{field_violations.join("; ")}")
        end
        inherited_flags = AuthorFrame.recompute_drafting_taint(graph, record_data)
      end
    end

    artifact_ids = [] of String
    files.keys.sort!.each do |rel_path|
      text = files[rel_path]
      artifact = graph.add_object("artifact", {
        "kind"     => JSON::Any.new("pack_source"),
        "title"    => JSON::Any.new(rel_path),
        "content"  => JSON::Any.new(text),
        "format"   => JSON::Any.new(rel_path.ends_with?(".toml") ? "toml" : "python"),
        "status"   => JSON::Any.new("draft"),
        "metadata" => JSON::Any.new({"pack_name" => JSON::Any.new(pack_name)}),
      }.to_json, actor: "evolution.submit_proposal")
      artifact_ids << artifact.id
    end

    proposal = graph.add_object("mod_proposal", {
      "gap_id"              => JSON::Any.new(gap_id),
      "drafting_context_id" => JSON::Any.new(drafting_context_id),
      "pack_name"           => JSON::Any.new(pack_name),
      "pack_version"        => JSON::Any.new(pack_version),
      "source_artifact_ids" => JSON::Any.new(artifact_ids.map { |id| JSON::Any.new(id) }),
      "bundle_hash"         => JSON::Any.new(Materialize.bundle_hash_of(files)),
      "rationale"           => JSON::Any.new(rationale),
      "authored_by"         => JSON::Any.new(authored_by),
      "injection_flags"     => JSON::Any.new(inherited_flags.map { |flag| JSON::Any.new(flag) }),
      "status"              => JSON::Any.new("drafted"),
    }.to_json, actor: "evolution.submit_proposal")
    if !gap_id.empty? && graph.get_object(gap_id)
      begin
        graph.add_relation(proposal.id, gap_id, "proposes_fix_for", actor: "evolution.submit_proposal")
      rescue
      end
    end
    proposal
  end

  # Open a reflection gap with DETERMINISTIC taint inheritance.
  #
  # The gap's injection_flags are the union of the flags on every reviewed
  # capability_result, computed from `reviewed_result_ids` (the review's
  # full input set), regardless of what the reviewer chose to put in
  # `evidence_refs`.
  def self.open_reflection_gap_fn(
    graph : Chronicle::GraphProjection,
    *,
    description : String,
    reviewed_result_ids : Array(String),
    evidence_refs : Array(String)? = nil,
  ) : Chronicle::GraphObject
    inherited = Set(String).new
    reviewed_result_ids.each do |result_id|
      obj = graph.get_object(result_id)
      if obj
        (JSON.parse(obj.data)["injection_flags"]?.try(&.as_a) || [] of JSON::Any).each do |flag|
          inherited << flag.as_s
        end
      end
    end
    graph.add_object("capability_gap", {
      "kind"            => JSON::Any.new("reflection"),
      "description"     => JSON::Any.new(description),
      "evidence_refs"   => JSON::Any.new((evidence_refs || [] of String).map { |id| JSON::Any.new(id) }),
      "injection_flags" => JSON::Any.new(inherited.to_a.sort.map { |flag| JSON::Any.new(flag) }),
      "status"          => JSON::Any.new("open"),
      "metadata"        => JSON::Any.new({"reviewed_result_ids" => JSON::Any.new(reviewed_result_ids.map { |id| JSON::Any.new(id) })}),
    }.to_json, actor: "evolution.open_reflection_gap")
  end

  # Propose adoption through the gateway: records the capability_call and
  # holds it (critical is never auto-approvable).
  def self.request_adoption_fn(graph : Chronicle::GraphProjection, *, proposal_id : String, proposed_by : String, note : String = "") : Hash(String, JSON::Any)
    spec = ToolGateway.get_capability_spec("evolution.adopt_proposal")
    if spec.nil?
      return {"error" => JSON::Any.new("evolution.adopt_proposal is not registered")}
    end
    decision = ToolGateway.decide_policy(spec.risk_class, ToolGateway::ToolGatewaySettings.new)
    call = graph.add_object("capability_call", {
      "provider_id"     => JSON::Any.new(""),
      "provider_name"   => JSON::Any.new(spec.provider_name),
      "capability_name" => JSON::Any.new(spec.capability_name),
      "input_data"      => JSON::Any.new({"proposal_id" => JSON::Any.new(proposal_id), "note" => JSON::Any.new(note)}),
      "risk_class"      => JSON::Any.new(spec.risk_class),
      "status"          => JSON::Any.new(decision == "auto_approve" ? "approved" : "policy_checking"),
      "proposed_by"     => JSON::Any.new(proposed_by),
      "proposed_at"     => JSON::Any.new(_now),
      "metadata"        => JSON::Any.new({"initiated_by" => JSON::Any.new("evolution.request_adoption")}),
    }.to_json, actor: "evolution.request_adoption")
    _merge_patch(graph, proposal_id, {"status" => JSON::Any.new("pending_approval")}, "evolution.request_adoption")
    {"call_id" => JSON::Any.new(call.id), "status" => JSON::Any.new(JSON.parse(call.data)["status"].as_s)}
  end
end

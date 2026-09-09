require "json"
require "time"
require "file_utils"

module Chronicle::Packs::Evolution
  # Stage-4/5 adoption: governed decision, two-phase execution. Ported from
  # upstream packs/evolution/adopt.py (slice 1: the registration surface
  # with its two safety refusals and the phase-one ticket executors).
  #
  # Phase one (governed): `evolution.adopt_proposal` and
  # `evolution.disable_promotion` are gateway capabilities. Registration
  # REFUSES in configurations where the governance would be theater: a
  # gateway policy that would auto-approve `critical`, or an identity setup
  # with no verified approver. Their executors run only after an approved
  # capability call, and all they do is write an adoption_ticket.
  #
  # Candidate activation remains deferred: it needs a Crystal runtime source
  # loader and persisted fork promotion. The independent disable and
  # supersession reconciliation path is safe to run now because it operates
  # only on already-recorded promotion state.
  module AdoptConstants
    AdoptConstants::ADOPT_RISK = "critical"
    AdoptConstants::DISABLE_RISK = "high"
    AdoptConstants::ADOPT_ACTION_CLASS = "R4"
    AdoptConstants::DISABLE_ACTION_CLASS = "R4"
  end

  # The graph the governed capability executors operate on. chronicle's
  # gateway handler receives only input_data (no execution_context with a
  # graph); hosts bind one here when the pack is wired into a runtime (see
  # the identity_auth seam precedent).
  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "evolution governed capabilities require a bound graph (set Evolution.bound_graph)"
    )
  end

  def self._verified_approver_exists(graph : Chronicle::GraphProjection, approver_roles : Array(String)) : {Bool, String}
    unless IdentityAuth.principals_registered
      return {false, "no principals registered"}
    end
    graph.objects(type: "principal").each do |obj|
      role = JSON.parse(obj.data)["role"]?.try(&.as_s?)
      if role && approver_roles.includes?(role)
        return {true, ""}
      end
    end
    {false, "no principal holds an approver role #{approver_roles}"}
  end

  # Register the two governed capabilities, refusing unsafe configs.
  #
  # Two refusals: auto-approvable critical means the hold is fiction;
  # unverified identity means "approved by the owner" is fiction.
  # Unverified-mode self-modification must not exist.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream register_adoption_capabilities + executors
  def self.register_adoption_capabilities(*, gateway_settings : ToolGateway::ToolGatewaySettings, graph : Chronicle::GraphProjection) : Nil
    if gateway_settings.auto_approve_risk_classes.includes?(AdoptConstants::ADOPT_RISK)
      raise PackError.new(
        "evolution.adopt_proposal refuses to register: gateway settings auto-approve #{AdoptConstants::ADOPT_RISK.inspect}, so the owner hold would never happen. Self-modification without a held approval must not exist."
      )
    end
    ok, reason = _verified_approver_exists(graph, gateway_settings.approver_roles)
    unless ok
      raise PackError.new(
        "evolution.adopt_proposal refuses to register: approver verification is not possible (#{reason}). Unverified-mode self-modification must not exist; load identity_auth and register an owner principal first."
      )
    end

    ToolGateway.register_local_capability(
      "evolution", "adopt_proposal",
      ->(input : Hash(String, JSON::Any)) {
        proposal_id = input["proposal_id"]?.try(&.as_s?) || ""
        note = input["note"]?.try(&.as_s?) || ""
        g = bound_graph_or_raise
        proposal = g.get_object(proposal_id)
        if proposal.nil? || proposal.type != "mod_proposal"
          raise PackError.new("no mod_proposal #{proposal_id.inspect}")
        end
        status = JSON.parse(proposal.data)["status"]?.try(&.as_s?) || ""
        unless status.in?({"trialed", "pending_approval"})
          raise PackError.new("proposal is #{status.inspect}; adoption requires 'trialed' (or 'pending_approval' when the request already moved it)")
        end
        ticket = g.add_object("adoption_ticket", {
          "kind"        => JSON::Any.new("adopt"),
          "proposal_id" => JSON::Any.new(proposal_id),
          "call_id"     => JSON::Any.new(input["call_id"]?.try(&.as_s?) || ""),
          "reason"      => JSON::Any.new(note),
          "status"      => JSON::Any.new("open"),
          "at"          => JSON::Any.new(_now),
        }.to_json, actor: "evolution.adopt_proposal")
        g.patch_object(proposal_id, {"status" => JSON::Any.new("adopting")}.to_json, actor: "evolution.adopt_proposal")
        {"ticket_id" => JSON::Any.new(ticket.id), "note" => JSON::Any.new("adoption queued; the chassis applies it between frames")}
      },
      description: "Adopt a gated-and-trialed agent-authored pack: load it and promote its trial state. Critical risk: always held for a verified owner approval.",
      risk_class: AdoptConstants::ADOPT_RISK,
      action_class: AdoptConstants::ADOPT_ACTION_CLASS,
    )
    ToolGateway.register_local_capability(
      "evolution", "disable_promotion",
      ->(input : Hash(String, JSON::Any)) {
        promotion_id = input["promotion_id"]?.try(&.as_s?) || ""
        reason = input["reason"]?.try(&.as_s?) || ""
        g = bound_graph_or_raise
        promotion = g.get_object(promotion_id)
        if promotion.nil? || promotion.type != "mod_promotion"
          raise PackError.new("no mod_promotion #{promotion_id.inspect}")
        end
        ticket = g.add_object("adoption_ticket", {
          "kind"         => JSON::Any.new("disable"),
          "promotion_id" => JSON::Any.new(promotion_id),
          "call_id"      => JSON::Any.new(input["call_id"]?.try(&.as_s?) || ""),
          "reason"       => JSON::Any.new(reason),
          "status"       => JSON::Any.new("open"),
          "at"           => JSON::Any.new(_now),
        }.to_json, actor: "evolution.disable_promotion")
        {"ticket_id" => JSON::Any.new(ticket.id), "note" => JSON::Any.new("disable queued; the chassis applies it between frames")}
      },
      description: "Disable an adopted pack: immediate deregistration plus boot-time exclusion.",
      risk_class: AdoptConstants::DISABLE_RISK,
      action_class: AdoptConstants::DISABLE_ACTION_CLASS,
    )
  end

  # Process open adoption tickets between frames. Adoption performs every
  # durable precondition in the parent—pin, static gates, passing fork, and
  # conflict dry-run—but deliberately stops before host-owned activation.
  # There is no fallback that loads candidate source in this process.
  def self.process_adoption_tickets(rt : Chronicle::Runtime(M), settings : EvolutionSettings) : Array(Hash(String, JSON::Any)) forall M
    graph = rt.graph || raise PackError.new("evolution disable processing requires an attached graph")
    graph.objects(type: "adoption_ticket")
      .select { |ticket| ticket_data(ticket)["status"]?.try(&.as_s?) == "open" }
      .map do |ticket|
        ticket_data(ticket)["kind"]?.try(&.as_s?) == "disable" ? process_disable_ticket(rt, graph, ticket) : process_adopt_preflight(rt, graph, ticket, settings)
      end
  end

  # Compatibility entry point for callers that only want the already-complete
  # disable path.
  def self.process_disable_tickets(rt : Chronicle::Runtime(M)) : Array(Hash(String, JSON::Any)) forall M
    graph = rt.graph || raise PackError.new("evolution disable processing requires an attached graph")
    graph.objects(type: "adoption_ticket")
      .select { |ticket| ticket_data(ticket)["status"]?.try(&.as_s?) == "open" }
      .select { |ticket| ticket_data(ticket)["kind"]?.try(&.as_s?) == "disable" }
      .map { |ticket| process_disable_ticket(rt, graph, ticket) }
  end

  # Disable every other active promotion for a pack after a new promotion has
  # reached active state. This is bookkeeping only: the runtime already holds
  # the newly loaded code, so disabling the old record must not deregister it.
  def self.supersede_prior_actives(graph : Chronicle::GraphProjection, pack_name : String, new_id : String) : Array(String)
    superseded = [] of String
    graph.objects(type: "mod_promotion").each do |promotion|
      next if promotion.id == new_id
      data = ticket_data(promotion)
      next unless data["pack_name"]?.try(&.as_s?) == pack_name
      next unless data["status"]?.try(&.as_s?) == "active"

      metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
      metadata["superseded_by"] = JSON::Any.new(new_id)
      graph.patch_object(promotion.id, {
        "status"      => JSON::Any.new("disabled"),
        "status_note" => JSON::Any.new("superseded by #{new_id}"),
        "metadata"    => JSON::Any.new(metadata),
      }.to_json, actor: "evolution.adopt")
      superseded << promotion.id
    end
    superseded
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful idempotent disable transaction
  private def self.process_disable_ticket(rt : Chronicle::Runtime(M), graph : Chronicle::GraphProjection, ticket : Chronicle::GraphObject) : Hash(String, JSON::Any) forall M
    ticket_data = ticket_data(ticket)
    promotion_id = ticket_data["promotion_id"]?.try(&.as_s?) || ""
    promotion = graph.get_object(promotion_id)
    if promotion.nil?
      abort_ticket(graph, ticket.id, nil, "promotion vanished")
      return disable_outcome(ticket.id, "error")
    end

    promotion_data = ticket_data(promotion)
    if promotion_data["status"]?.try(&.as_s?) == "disabled" && graph.objects(type: "mod_rollback").any? { |rollback| ticket_data(rollback)["promotion_id"]?.try(&.as_s?) == promotion_id }
      graph.patch_object(ticket.id, {"status" => JSON::Any.new("done")}.to_json, actor: "evolution.adopt")
      return disable_outcome(ticket.id, "disabled", false, "already disabled")
    end

    pack_name = promotion_data["pack_name"]?.try(&.as_s?) || ""
    deregistered = false
    begin
      deregistered = rt.disable_pack(pack_name)
    rescue
      # A loading-state promotion may not be registered in this runtime. Its
      # durable disabled record is still the canonical boot exclusion.
    end
    graph.patch_object(promotion_id, {"status" => JSON::Any.new("disabled")}.to_json, actor: "evolution.adopt")
    rollback = graph.add_object("mod_rollback", {
      "promotion_id" => JSON::Any.new(promotion_id),
      "method"       => JSON::Any.new(deregistered ? "disable_pack" : "boot_exclusion"),
      "reason"       => JSON::Any.new(ticket_data["reason"]?.try(&.as_s?) || ""),
      "at"           => JSON::Any.new(_now),
    }.to_json, actor: "evolution.adopt")
    begin
      graph.add_relation(promotion_id, rollback.id, "rolled_back_by", actor: "evolution.adopt")
    rescue
      # Preserve the rollback object if a legacy graph lacks this relation.
    end
    proposal_id = promotion_data["proposal_id"]?.try(&.as_s?) || ""
    graph.patch_object(proposal_id, {"status" => JSON::Any.new("disabled")}.to_json, actor: "evolution.adopt") unless proposal_id.empty? || graph.get_object(proposal_id).nil?
    graph.patch_object(ticket.id, {"status" => JSON::Any.new("done")}.to_json, actor: "evolution.adopt")
    disable_outcome(ticket.id, "disabled", deregistered)
  end

  # Stages 1–3 of the vendor adoption order. The full activation stage needs
  # a host service which can map a verified compiled artifact to a sealed
  # pack implementation; this phase must never approximate that with require.
  # ameba:disable Metrics/CyclomaticComplexity -- canonical preflight must preserve each fail-closed vendor outcome
  private def self.process_adopt_preflight(rt : Chronicle::Runtime(M), graph : Chronicle::GraphProjection, ticket : Chronicle::GraphObject, settings : EvolutionSettings) : Hash(String, JSON::Any) forall M
    proposal_id = ticket_data(ticket)["proposal_id"]?.try(&.as_s?) || ""
    proposal = graph.get_object(proposal_id)
    if proposal.nil? || proposal.type != "mod_proposal"
      abort_ticket(graph, ticket.id, nil, "proposal vanished")
      return adoption_outcome(ticket.id, "error")
    end
    if ticket_data(proposal)["status"]?.try(&.as_s?) == "needs_owner"
      abort_ticket(graph, ticket.id, nil, "proposal is needs_owner (terminal); owner action required")
      return adoption_outcome(ticket.id, "needs_owner")
    end

    begin
      files, root = Materialize.materialize_verified(graph, proposal)
      begin
        unless rerun_static_gates(graph, proposal, files, settings)
          abort_ticket(graph, ticket.id, proposal.id, "gates failed on re-run", "gated")
          return adoption_outcome(ticket.id, "gates_failed")
        end
      ensure
        FileUtils.rm_rf(root.parent)
      end
    rescue ex : Chronicle::Packs::PackManifestError
      abort_ticket(graph, ticket.id, proposal.id, "bundle-hash pin failed: #{ex}")
      return adoption_outcome(ticket.id, "hash_mismatch")
    rescue ex
      abort_ticket(graph, ticket.id, proposal.id, "materialization failed: #{ex}")
      return adoption_outcome(ticket.id, "error")
    end

    graph.patch_object(proposal.id, {"status" => JSON::Any.new("adopting")}.to_json, actor: "evolution.adopt")
    passing = graph.objects(type: "mod_trial").select do |trial|
      data = ticket_data(trial)
      data["proposal_id"]?.try(&.as_s?) == proposal.id && data["verdict"]?.try(&.as_s?) == "pass"
    end
    fork_run_id = passing.last?.try { |trial| ticket_data(trial)["fork_run_id"]?.try(&.as_s?) } || ""
    fork = Trial.load_trial_fork(rt, fork_run_id)
    if fork.nil?
      abort_ticket(graph, ticket.id, proposal.id, "trial fork not available in the store (never trialed, or its run was retired); re-trial required", "gated")
      return adoption_outcome(ticket.id, "retrial_required")
    end

    plan = rt.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    unless plan.is_promotable
      abort_ticket(graph, ticket.id, proposal.id, "promote conflicts: #{plan.conflicts.first(5)}", "conflict")
      return adoption_outcome(ticket.id, "conflict")
    end
    adoption_outcome(ticket.id, "activation_pending")
  rescue ex : Chronicle::IncompatibleRuntimeState | Chronicle::PromoteLineageError
    abort_ticket(graph, ticket.id, proposal_id, "trial fork not available in the store (#{ex.message || ex.class.name}); re-trial required", "gated")
    adoption_outcome(ticket.id, "retrial_required")
  end

  private def self.rerun_static_gates(graph : Chronicle::GraphProjection, proposal : Chronicle::GraphObject, files : Hash(String, String), settings : EvolutionSettings) : Bool
    data = ticket_data(proposal)
    config = Analysis::CrystalStaticGateConfig.new(
      allowed_files: settings.crystal_allowed_files,
      allowed_requires: settings.crystal_require_allow,
      reserved_paths: settings.reserved_paths,
      reserved_namespaces: settings.reserved_namespaces,
      never_callable: ToolGateway::Untrusted::NEVER_LLM_CALLABLE.to_a,
      max_total_source_bytes: settings.max_total_source_bytes,
      max_file_source_bytes: settings.max_file_bytes,
      expected_bundle_hash: data["bundle_hash"]?.try(&.as_s?) || "",
      expected_pack_name: data["pack_name"]?.try(&.as_s?) || "",
    )
    Analysis.crystal_static_gate_results(files, config).each do |gate, violations|
      record_adopt_gate(graph, proposal.id, gate, violations.empty? ? "pass" : "fail", violations.join("; "))
      return false unless violations.empty?
    end
    flags = files.each_value.flat_map { |source| ToolGateway::Untrusted.scan_for_injection(source) }.to_a.uniq.sort!
    record_adopt_gate(graph, proposal.id, "static:injection", flags.empty? ? "pass" : "suspended", flags.join(", "))
    flags.empty?
  end

  private def self.record_adopt_gate(graph : Chronicle::GraphProjection, proposal_id : String, gate : String, verdict : String, details : String) : Nil
    result = graph.add_object("gate_result", {
      "proposal_id" => JSON::Any.new(proposal_id), "gate" => JSON::Any.new(gate),
      "verdict" => JSON::Any.new(verdict), "details" => JSON::Any.new(details),
      "at" => JSON::Any.new(_now),
    }.to_json, actor: "evolution.adopt")
    graph.add_relation(proposal_id, result.id, "gated_by", actor: "evolution.adopt")
  end

  private def self.adoption_outcome(ticket_id : String, outcome : String) : Hash(String, JSON::Any)
    {"ticket" => JSON::Any.new(ticket_id), "outcome" => JSON::Any.new(outcome)}
  end

  private def self.abort_ticket(graph : Chronicle::GraphProjection, ticket_id : String, proposal_id : String?, note : String, proposal_status : String = "suspended") : Nil
    graph.patch_object(ticket_id, {
      "status"      => JSON::Any.new("aborted"),
      "status_note" => JSON::Any.new(note[0, Math.min(note.size, 500)]),
    }.to_json, actor: "evolution.adopt")
    unless proposal_id.nil? || proposal_id.empty? || graph.get_object(proposal_id).nil?
      graph.patch_object(proposal_id, {
        "status"      => JSON::Any.new(proposal_status),
        "status_note" => JSON::Any.new(note[0, Math.min(note.size, 300)]),
      }.to_json, actor: "evolution.adopt")
    end
  end

  private def self.disable_outcome(ticket_id : String, outcome : String, deregistered : Bool = false, note : String? = nil) : Hash(String, JSON::Any)
    result = {
      "ticket"       => JSON::Any.new(ticket_id),
      "outcome"      => JSON::Any.new(outcome),
      "deregistered" => JSON::Any.new(deregistered),
    }
    result["note"] = JSON::Any.new(note) unless note.nil?
    result
  end

  private def self.ticket_data(object : Chronicle::GraphObject) : Hash(String, JSON::Any)
    JSON.parse(object.data).as_h
  end
end

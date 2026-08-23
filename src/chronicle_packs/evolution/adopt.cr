require "json"
require "time"

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
  # Phase two (chassis, process_adoption_tickets) is DEFERRED: it needs the
  # Python-materialization pipeline (materialize_verified / import_pack) and
  # runtime fork promotion.
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
end

require "json"
require "time"

module Chronicle::Packs::Evolution
  # Between-frame governance sweep. Conflict retry is bounded because the
  # reviewed bundle has not changed; only unrelated parent state advanced
  # while the trial fork was in flight.
  module Chassis
    RETRYABLE_OUTCOMES = Set{"conflict", "conflict_late", "retrial_required"}

    def self.sweep_evolution(rt : Chronicle::Runtime(M), settings : EvolutionSettings) : Array(Hash(String, JSON::Any)) forall M
      outcomes = Chronicle::Packs::Evolution.process_adoption_tickets(rt, settings)
      graph = rt.graph || raise PackError.new("evolution chassis requires an attached graph")
      outcomes.each do |outcome|
        next unless RETRYABLE_OUTCOMES.includes?(outcome["outcome"]?.try(&.as_s?) || "")

        ticket = graph.get_object(outcome["ticket"]?.try(&.as_s?) || "")
        next unless ticket
        proposal_id = ticket_data(ticket)["proposal_id"]?.try(&.as_s?) || ""
        proposal = graph.get_object(proposal_id)
        next if proposal.nil?
        handle_retry(graph, ticket, proposal, outcome, settings)
      end
      outcomes
    end

    private def self.handle_retry(graph : Chronicle::GraphProjection, ticket : Chronicle::GraphObject, proposal : Chronicle::GraphObject, outcome : Hash(String, JSON::Any), settings : EvolutionSettings) : Nil
      data = ticket_data(proposal)
      metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
      retries = metadata["auto_retries"]?.try(&.as_i?) || 0
      if retries >= settings.max_conflict_retries
        graph.patch_object(proposal.id, {
          "status"      => JSON::Any.new("needs_owner"),
          "status_note" => JSON::Any.new("parked after #{retries} automatic conflict #{retries == 1 ? "retry" : "retries"} (cap #{settings.max_conflict_retries}); the target state is contested and needs the owner"),
        }.to_json, actor: "evolution.chassis")
        outcome["retry"] = JSON::Any.new("needs_owner")
        return
      end

      retries += 1
      metadata["auto_retries"] = JSON::Any.new(retries)
      graph.patch_object(proposal.id, {
        "status"      => JSON::Any.new("gated"),
        "metadata"    => JSON::Any.new(metadata),
        "status_note" => JSON::Any.new("auto retry #{retries} of #{settings.max_conflict_retries}"),
      }.to_json, actor: "evolution.chassis")
      trial = Trial.run_trial(graph, proposal, settings)
      if trial.verdict != "pass"
        outcome["retry"] = JSON::Any.new("retrial_failed")
        return
      end

      graph.add_object("adoption_ticket", {
        "kind"        => JSON::Any.new("adopt"),
        "proposal_id" => JSON::Any.new(proposal.id),
        "call_id"     => JSON::Any.new(ticket_data(ticket)["call_id"]?.try(&.as_s?) || ""),
        "reason"      => JSON::Any.new("automatic conflict retry #{retries} of #{settings.max_conflict_retries} (same approved call; the bundle-hash pin is unchanged)"),
        "status"      => JSON::Any.new("open"),
        "at"          => JSON::Any.new(Time.utc.to_rfc3339),
        "metadata"    => JSON::Any.new({"retry_of" => JSON::Any.new(ticket.id), "auto_retry" => JSON::Any.new(retries)}),
      }.to_json, actor: "evolution.chassis")
      outcome["retry"] = JSON::Any.new("requeued (#{retries}/#{settings.max_conflict_retries})")
    end

    private def self.ticket_data(object : Chronicle::GraphObject) : Hash(String, JSON::Any)
      JSON.parse(object.data).as_h
    end
  end
end

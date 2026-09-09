require "json"

module Chronicle::Packs::Evolution
  # Durable Evolution housekeeping. Candidate activation/reload remains a
  # later phase; this module only operates on completed trial-fork evidence.
  module Boot
    TRIAL_LABEL_PREFIXES    = ["evolution-trial:", "evolution-fixturegate:"]
    FORK_RETAINING_STATUSES = ["trialed", "pending_approval", "adopting", "needs_owner"]

    # Reconcile durable promotion records before the later host-bound Crystal
    # activation phase. It deliberately never loads candidate code. Every
    # state repair is evidence-backed and emits a reflection gap.
    def self.reconcile_promotions(graph : Chronicle::GraphProjection) : Hash(String, String)
      promoted_runs = graph.events.select { |event| event.type == "promote.applied" }.compact_map do |event|
        JSON.parse(event.payload)["from_run"]?.try(&.as_s?)
      rescue JSON::ParseException
        nil
      end.to_set
      outcomes = {} of String => String
      graph.objects(type: "mod_promotion").group_by { |promotion| JSON.parse(promotion.data)["pack_name"]?.try(&.as_s?) || "?" }.each do |name, promotions|
        promotions.each do |promotion|
          data = JSON.parse(promotion.data)
          next unless data["status"]?.try(&.as_s?) == "loading"
          proposal_id = data["proposal_id"]?.try(&.as_s?) || ""
          fork_run_id = data["fork_run_id"]?.try(&.as_s?) || ""
          if !fork_run_id.empty? && promoted_runs.includes?(fork_run_id)
            graph.patch_object(promotion.id, {"status" => JSON::Any.new("active"), "status_note" => JSON::Any.new("healed at boot: promote.applied present in the log")}.to_json, actor: "evolution.boot")
            close_open_adoption_tickets(graph, proposal_id)
            boot_gap(graph, name, promotion.id, "loading_with_marker")
            outcomes[name] = "active (healed; activation pending)"
          else
            graph.patch_object(promotion.id, {"status" => JSON::Any.new("disabled"), "status_note" => JSON::Any.new("parked at boot: incomplete adoption, no promote.applied in the log")}.to_json, actor: "evolution.boot")
            boot_gap(graph, name, promotion.id, "loading_no_marker")
            outcomes[name] = "disabled (parked incomplete adoption)"
          end
        end
        reconcile_duplicate_actives(graph, name, promotions, outcomes)
      end
      outcomes
    end

    private def self.reconcile_duplicate_actives(graph : Chronicle::GraphProjection, pack_name : String, promotions : Array(Chronicle::GraphObject), outcomes : Hash(String, String)) : Nil
      active = promotions.select do |promotion|
        graph.get_object(promotion.id).try { |current| JSON.parse(current.data)["status"]?.try(&.as_s?) == "active" } || false
      end
      return unless active.size >= 2

      survivor = active.last
      active[0...-1].each do |loser|
        data = JSON.parse(loser.data)
        metadata = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
        metadata["superseded_by"] = JSON::Any.new(survivor.id)
        graph.patch_object(loser.id, {"status" => JSON::Any.new("disabled"), "status_note" => JSON::Any.new("superseded by #{survivor.id} (boot heal)"), "metadata" => JSON::Any.new(metadata)}.to_json, actor: "evolution.boot")
      end
      boot_gap(graph, pack_name, survivor.id, "two_active")
      outcomes[pack_name] = "active (healed; activation pending)"
    end

    private def self.close_open_adoption_tickets(graph : Chronicle::GraphProjection, proposal_id : String) : Nil
      graph.objects(type: "adoption_ticket").each do |ticket|
        data = JSON.parse(ticket.data)
        next unless data["proposal_id"]?.try(&.as_s?) == proposal_id && data["status"]?.try(&.as_s?) == "open"
        graph.patch_object(ticket.id, {"status" => JSON::Any.new("done"), "status_note" => JSON::Any.new("closed by boot heal: promote already applied")}.to_json, actor: "evolution.boot")
      end
    end

    private def self.boot_gap(graph : Chronicle::GraphProjection, pack_name : String, promotion_id : String, recovery_case : String) : Nil
      graph.add_object("capability_gap", {"kind" => JSON::Any.new("reflection"), "description" => JSON::Any.new("adopted pack #{pack_name.inspect}: boot reconciled promotion #{promotion_id}"), "status" => JSON::Any.new("open"), "metadata" => JSON::Any.new({"source" => JSON::Any.new("boot_heal"), "promotion_id" => JSON::Any.new(promotion_id), "pack_name" => JSON::Any.new(pack_name), "case" => JSON::Any.new(recovery_case)})}.to_json, actor: "evolution.boot")
    end

    # Archive trial forks which are neither retained by an adoptable proposal
    # nor pinned by Chronicle's provenance/lineage rules. This only touches
    # fork runs; it is safe while a parent runtime remains attached elsewhere
    # in the same SQLite database.
    def self.retire_unpinned_trial_forks(store_path : String) : Hash(String, String)
      retained = retained_fork_ids(store_path)
      outcomes = {} of String => String
      Chronicle::SQLiteEventStore.list_runs(store_path).each do |record|
        next unless trial_label?(record.label)

        if retained.includes?(record.run_id)
          outcomes[record.run_id] = "in-flight (kept)"
          next
        end

        reasons = Chronicle::Retention.pins(store_path, record.run_id)
        unless reasons.empty?
          outcomes[record.run_id] = "pinned: #{reasons.first}"
          next
        end

        begin
          rows = Chronicle::Retention.retire(store_path, record.run_id)
          outcomes[record.run_id] = "retired (#{rows} rows archived)"
        rescue ex : Chronicle::Retention::RetentionPinnedError
          outcomes[record.run_id] = "pinned: #{ex.reasons.first? || ex.message || ex.class.name}"
        rescue ex
          outcomes[record.run_id] = "error: #{ex.message || ex.class.name}"
        end
      end
      outcomes
    end

    private def self.trial_label?(label : String?) : Bool
      value = label || ""
      TRIAL_LABEL_PREFIXES.any? { |prefix| value.starts_with?(prefix) }
    end

    # Read only root runs: a recent trial fork can be the store's newest run,
    # but proposals live on its parent/root and decide whether that fork can
    # still be adopted. Projection replay is evidence-only and attaches no
    # pack registrations or behaviors.
    private def self.retained_fork_ids(store_path : String) : Set(String)
      retained = Set(String).new
      Chronicle::SQLiteEventStore.list_runs(store_path).each do |record|
        next unless record.parent_run_id.nil?

        store = Chronicle::SQLiteEventStore.new(store_path, run_id: record.run_id)
        begin
          graph = Chronicle::GraphProjection.replay(store.iter_events)
          proposal_statuses = graph.objects(type: "mod_proposal").to_h do |proposal|
            data = JSON.parse(proposal.data).as_h
            {proposal.id, data["status"]?.try(&.as_s?) || ""}
          end
          graph.objects(type: "mod_trial").each do |trial|
            data = JSON.parse(trial.data).as_h
            proposal_id = data["proposal_id"]?.try(&.as_s?) || ""
            fork_run_id = data["fork_run_id"]?.try(&.as_s?) || ""
            retained << fork_run_id if FORK_RETAINING_STATUSES.includes?(proposal_statuses[proposal_id]? || "") && !fork_run_id.empty?
          end
        rescue
          # An unreadable root cannot establish a keep relationship. The
          # retention API's own pins still protect provenance and lineage.
        ensure
          store.close
        end
      end
      retained
    end
  end
end

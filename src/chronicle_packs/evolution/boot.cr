require "json"

module Chronicle::Packs::Evolution
  # Durable Evolution housekeeping. Candidate activation/reload remains a
  # later phase; this module only operates on completed trial-fork evidence.
  module Boot
    TRIAL_LABEL_PREFIXES    = ["evolution-trial:", "evolution-fixturegate:"]
    FORK_RETAINING_STATUSES = ["trialed", "pending_approval", "adopting", "needs_owner"]

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

require "file_utils"
require "json"

module Chronicle::Packs::Evolution
  # A bounded request for a host-owned, isolated candidate trial. The pack
  # supplies only reviewed source identity and limits; the host owns the
  # child process, its allow-listed environment, and persisted fork.
  record TrialRequest,
    proposal_id : String,
    pack_name : String,
    candidate_root : Path,
    bundle_hash : String,
    at_event : String,
    fixture_timeout_seconds : Float64,
    wall_clock_seconds : Float64,
    max_rss_bytes : Int64,
    max_new_events : Int32

  # Durable evidence returned by one child run. The host must populate this
  # from the persisted fork rather than importing candidate source into the
  # parent process.
  record TrialReport,
    outcome : String,
    detail : String = "",
    fork_run_id : String = "",
    forked_at_event : String = "",
    behavior_failures : Int32 = 0,
    events_appended : Int32 = 0,
    in_sample_inputs : Int32 = 0,
    in_sample_failures : Int32 = 0,
    held_out_inputs : Int32 = 0,
    held_out_failures : Int32 = 0,
    residue_objects_removed : Int32 = 0,
    residue_relations_removed : Int32 = 0,
    diff_is_identical : Bool = false,
    failures : Array(Hash(String, String)) = [] of Hash(String, String)

  record TrialResult,
    verdict : String,
    gate : String = "",
    trial_id : String = ""

  abstract class TrialService
    abstract def run_fixture(request : TrialRequest) : TrialReport

    abstract def run_replay(request : TrialRequest) : TrialReport
  end

  # Stage-three coordinator. This deliberately has no fallback that invokes
  # `crystal`, requires the candidate, or loads its pack in this process. A
  # runtime binds the one service that can supply an isolated compiled-child
  # implementation for that graph.
  module Trial
    class_property services : Hash(Chronicle::GraphProjection, TrialService) = {} of Chronicle::GraphProjection => TrialService

    def self.set_service(graph : Chronicle::GraphProjection, service : TrialService) : Nil
      self.services[graph] = service
    end

    def self.service(graph : Chronicle::GraphProjection) : TrialService?
      self.services[graph]?
    end

    def self.clear_services : Nil
      self.services.clear
    end

    # Reload the durable replay fork strictly as evidence: no parent pack
    # registrations or behaviors are copied onto the reopened runtime. A
    # retired, unknown, empty, or otherwise unreadable run is not usable for
    # trial review or later promotion.
    def self.load_trial_fork(parent : Chronicle::Runtime(M), fork_run_id : String) : Chronicle::Runtime(M)? forall M
      return nil if fork_run_id.empty?

      store = parent.store
      unless store.is_a?(Chronicle::SQLiteEventStore)
        raise PackError.new("trial forks require a SQLite-backed runtime")
      end

      begin
        fork = Chronicle::Runtime(M).load(store.db_path, fork_run_id, parent.log_agent.agent)
        graph = fork.graph
        return nil if graph.nil? || graph.events.empty?
        fork
      rescue
        nil
      end
    end

    # Materialize and re-verify before handing a tree to an isolated host
    # service. Fixture failure is terminal; replay evidence is recorded as
    # the proposal's trial and determines trialed vs rejected.
    def self.run_trial(graph : Chronicle::GraphProjection, proposal : Chronicle::GraphObject, settings : EvolutionSettings) : TrialResult
      data = JSON.parse(proposal.data)
      status = data["status"]?.try(&.as_s?) || ""
      raise PackError.new("trial requires a gated proposal") unless status == "gated"

      pack_name = data["pack_name"]?.try(&.as_s?) || ""
      bundle_hash = data["bundle_hash"]?.try(&.as_s?) || ""
      _, root = Materialize.materialize_verified(graph, proposal)
      begin
        executor = service(graph)
        raise PackError.new("Crystal candidate trial requires a host-bound isolated TrialService") if executor.nil?

        request = TrialRequest.new(
          proposal.id, pack_name, root, bundle_hash, graph.events.last?.try(&.id) || "",
          settings.trial_fixture_timeout_seconds, settings.trial_wall_clock_seconds,
          settings.trial_max_rss_bytes, settings.trial_max_new_events,
        )
        fixture = executor.run_fixture(request)
        return fixture_failure(graph, proposal.id, fixture) unless fixture_passes?(fixture)
        record_gate(graph, proposal.id, "fixtures", "pass", report_details(fixture))

        finish_replay(graph, proposal.id, executor.run_replay(request))
      ensure
        FileUtils.rm_rf(root.parent)
      end
    end

    private def self.fixture_passes?(report : TrialReport) : Bool
      report.outcome == "completed" && report.behavior_failures == 0
    end

    private def self.fixture_failure(graph : Chronicle::GraphProjection, proposal_id : String, report : TrialReport) : TrialResult
      record_gate(graph, proposal_id, "fixtures", "fail", report_details(report))
      reject(graph, proposal_id, "fixtures: #{report_details(report)}")
      TrialResult.new("fail", "fixtures")
    end

    private def self.finish_replay(graph : Chronicle::GraphProjection, proposal_id : String, replay : TrialReport) : TrialResult
      record_replay_gates(graph, proposal_id, replay)
      verdict = replay_passes?(replay) ? "pass" : "fail"
      trial = graph.add_object("mod_trial", trial_payload(proposal_id, replay, verdict).to_json, actor: "evolution.trial")
      graph.add_relation(proposal_id, trial.id, "trialed_in", actor: "evolution.trial")
      if verdict == "pass"
        graph.patch_object(proposal_id, {"status" => JSON::Any.new("trialed"), "status_note" => JSON::Any.new("")}.to_json, actor: "evolution.trial")
      else
        reject(graph, proposal_id, "trial failed (outcome=#{replay.outcome}, #{replay.behavior_failures} candidate failures)")
      end
      TrialResult.new(verdict, "", trial.id)
    end

    private def self.record_replay_gates(graph : Chronicle::GraphProjection, proposal_id : String, report : TrialReport) : Nil
      record_gate(graph, proposal_id, "in_sample", report.in_sample_failures == 0 ? "pass" : "fail", "#{report.in_sample_inputs} inputs, #{report.in_sample_failures} candidate failures")
      record_gate(graph, proposal_id, "held_out", report.held_out_failures == 0 ? "pass" : "fail", "#{report.held_out_inputs} inputs, #{report.held_out_failures} candidate failures")
      record_gate(graph, proposal_id, "trial", "fail", report_details(report)) unless report.outcome == "completed"
    end

    private def self.replay_passes?(report : TrialReport) : Bool
      report.outcome == "completed" && report.behavior_failures == 0 && report.in_sample_failures == 0 && report.held_out_failures == 0
    end

    private def self.record_gate(graph : Chronicle::GraphProjection, proposal_id : String, gate : String, verdict : String, details : String) : Nil
      result = graph.add_object("gate_result", {
        "proposal_id" => JSON::Any.new(proposal_id), "gate" => JSON::Any.new(gate),
        "verdict" => JSON::Any.new(verdict), "details" => JSON::Any.new(details),
        "at" => JSON::Any.new(Time.utc.to_rfc3339),
      }.to_json, actor: "evolution.trial")
      graph.add_relation(proposal_id, result.id, "gated_by", actor: "evolution.trial")
    end

    private def self.reject(graph : Chronicle::GraphProjection, proposal_id : String, note : String) : Nil
      graph.patch_object(proposal_id, {
        "status"      => JSON::Any.new("rejected"),
        "status_note" => JSON::Any.new(note[0, Math.min(note.size, 200)]),
      }.to_json, actor: "evolution.trial")
    end

    private def self.report_details(report : TrialReport) : String
      detail = report.detail.empty? ? report.outcome : "#{report.outcome}: #{report.detail}"
      detail[0, Math.min(detail.size, 500)]
    end

    private def self.trial_payload(proposal_id : String, report : TrialReport, verdict : String) : Hash(String, JSON::Any)
      failures = report.failures.first(20).map do |failure|
        JSON.parse(failure.to_json)
      end
      {
        "proposal_id"     => JSON::Any.new(proposal_id),
        "fork_run_id"     => JSON::Any.new(report.fork_run_id),
        "forked_at_event" => JSON::Any.new(report.forked_at_event),
        "eval_summary"    => JSON::Any.new({
          "in_sample_inputs"       => JSON::Any.new(report.in_sample_inputs),
          "held_out_inputs"        => JSON::Any.new(report.held_out_inputs),
          "new_events"             => JSON::Any.new(report.events_appended),
          "fixture_gate"           => JSON::Any.new("pass"),
          "child_outcome"          => JSON::Any.new(report.outcome),
          "child_detail"           => JSON::Any.new(report.detail),
          "replay_residue_removed" => JSON::Any.new({
            "objects"   => JSON::Any.new(report.residue_objects_removed),
            "relations" => JSON::Any.new(report.residue_relations_removed),
          }),
        }),
        "diff_summary" => JSON::Any.new({"is_identical" => JSON::Any.new(report.diff_is_identical)}),
        "failures"     => JSON::Any.new(failures),
        "verdict"      => JSON::Any.new(verdict),
        "at"           => JSON::Any.new(Time.utc.to_rfc3339),
      }
    end
  end
end

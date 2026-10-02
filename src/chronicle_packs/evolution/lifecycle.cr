require "json"

module Chronicle::Packs::Evolution
  # The one host-owned boundary for an executable Evolution lifecycle. A host
  # supplies both halves: a fresh-process trial executor and a resolver that
  # maps a reviewed bundle to an already sealed, compiled Pack. The parent
  # process never requires or evaluates candidate source.
  abstract class LifecycleService < TrialService
    abstract def pack_for(request : ActivationRequest) : Chronicle::Packs::Pack
  end

  private class LifecycleActivationService < ActivationService
    def initialize(@lifecycle : LifecycleService)
    end

    def pack_for(request : ActivationRequest) : Chronicle::Packs::Pack
      @lifecycle.pack_for(request)
    end
  end

  module Lifecycle
    def self.install(graph : Chronicle::GraphProjection, service : LifecycleService) : Nil
      Trial.set_service(graph, service)
      Evolution.set_activation_service(graph, LifecycleActivationService.new(service))
    end

    def self.clear : Nil
      Trial.clear_services
      Evolution.clear_activation_services
    end
  end

  # Production adapter for Chronicle's process-isolated sandbox. The caller
  # chooses the executor and sealed Pack resolver so deployment policy (for
  # example, a stronger sandbox or a signed compiled-artifact registry) stays
  # in the host rather than in this governance pack.
  class SandboxLifecycleService < LifecycleService
    getter executor : Chronicle::Sandbox::TrialExecutor

    def initialize(
      @store_path : String,
      @parent_run_id : String,
      @pack_resolver : Proc(ActivationRequest, Chronicle::Packs::Pack),
      @executor : Chronicle::Sandbox::TrialExecutor = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new,
      @fixture_scenario : String = TrialDriverConstants::TRIAL_DRIVER_PATH,
      @replay_scenario : String = TrialDriverConstants::TRIAL_DRIVER_PATH,
    )
    end

    def self.for_runtime(
      runtime : Chronicle::Runtime(M),
      pack_resolver : Proc(ActivationRequest, Chronicle::Packs::Pack),
      *,
      executor : Chronicle::Sandbox::TrialExecutor = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new,
      fixture_scenario : String = TrialDriverConstants::TRIAL_DRIVER_PATH,
      replay_scenario : String = TrialDriverConstants::TRIAL_DRIVER_PATH,
    ) : SandboxLifecycleService forall M
      store = runtime.store
      unless store.is_a?(Chronicle::SQLiteEventStore)
        raise PackError.new("Evolution lifecycle trials require a SQLite-backed runtime")
      end
      new(store.db_path, runtime.run_id, pack_resolver, executor, fixture_scenario, replay_scenario)
    end

    def run_fixture(request : TrialRequest) : TrialReport
      execute(request, @fixture_scenario, "evolution-fixturegate:#{request.proposal_id}", request.fixture_timeout_seconds)
    end

    def run_replay(request : TrialRequest) : TrialReport
      execute(request, @replay_scenario, "evolution-trial:#{request.proposal_id}", request.wall_clock_seconds)
    end

    def pack_for(request : ActivationRequest) : Chronicle::Packs::Pack
      @pack_resolver.call(request)
    end

    private def execute(request : TrialRequest, scenario : String, label : String, wall_clock_seconds : Float64) : TrialReport
      specification = Chronicle::Sandbox::TrialSpecification.new(
        store_path: @store_path,
        parent_run_id: @parent_run_id,
        at_event: request.at_event,
        pack_source: Chronicle::Sandbox::PackSource.new(request.candidate_root.to_s, request.bundle_hash),
        scenario: scenario,
        limits: Chronicle::Sandbox::TrialLimits.new(
          wall_clock_seconds: wall_clock_seconds,
          max_rss_bytes: request.max_rss_bytes,
          max_events: request.max_new_events,
          max_llm_calls: 0,
        ),
        label: label,
      )
      report = @executor.execute(specification.to_json).to_report
      TrialReport.new(
        outcome: report.outcome,
        detail: report.detail,
        fork_run_id: report.fork_run_id,
        forked_at_event: request.at_event,
        behavior_failures: report.behavior_failures,
        events_appended: report.events_appended,
      )
    end
  end
end

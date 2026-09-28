require "json"
require "time"
require "file_utils"

module Chronicle::Packs::Evolution
  # Durable, provider-free accounting for the Crystal host's Evolution soak
  # driver. The host owns runtime construction and isolated candidate
  # execution; this state is deliberately just the reproducible audit ledger.
  module Soak
    DEFAULT_MIN_DAYS     =  3
    DEFAULT_MIN_PER_PATH = 20
    SCENARIO_PATHS       = ["happy", "conflict_park", "disable_restart", "budget_events", "budget_wallclock", "budget_memory", "tainted"]

    class PathCount
      include JSON::Serializable

      property ok : Int32 = 0
      property anomalies : Int32 = 0

      def initialize(@ok : Int32 = 0, @anomalies : Int32 = 0)
      end
    end

    class State
      include JSON::Serializable

      property started_at : String
      property rotations : Int32
      property paths : Hash(String, PathCount)
      property anomaly_log : Array(String)
      property primary_run_id : String = ""
      property last_happy_promotion : String = ""

      def initialize(scenario_paths : Array(String), @started_at : String = Time.utc.to_rfc3339, @rotations : Int32 = 0)
        @paths = scenario_paths.to_h { |path| {path, PathCount.new} }
        @anomaly_log = [] of String
      end

      def advance_rotation : Nil
        @rotations += 1
      end

      def record(path : String, passed : Bool) : Nil
        count = @paths[path]? || raise PackError.new("unknown Evolution soak scenario #{path.inspect}")
        if passed
          count.ok += 1
        else
          count.anomalies += 1
          @anomaly_log << "#{path}: failed"
        end
      end

      def target_met?(min_per_path : Int32) : Bool
        @paths.each_value.all? { |count| count.ok >= min_per_path }
      end

      def completion_met?(elapsed_days : Int32, min_per_path : Int32 = DEFAULT_MIN_PER_PATH) : Bool
        elapsed_days >= DEFAULT_MIN_DAYS && target_met?(min_per_path: min_per_path)
      end

      # The portable review artifact: no host runtime, provider, or Python
      # process is needed to inspect whether every scenario has met its bar.
      def to_markdown(min_per_path : Int32) : String
        lines = ["# Evolution soak digest", "", "Rotations: #{@rotations}", "", "| Scenario | OK | Anomalies | Target |", "| --- | ---: | ---: | --- |"]
        @paths.keys.sort!.each do |path|
          count = @paths[path]
          status = count.ok >= min_per_path ? "met" : "pending"
          lines << "| #{path} | #{count.ok} | #{count.anomalies} | #{status} |"
        end
        lines << ""
        lines << "Overall: #{target_met?(min_per_path: min_per_path) ? "met" : "pending"}"
        unless @anomaly_log.empty?
          lines << ""
          lines << "## Recent anomalies"
          lines << ""
          @anomaly_log.last(20).each { |entry| lines << "- #{entry}" }
        end
        lines.join("\n") + "\n"
      end

      def save(path : String) : Nil
        File.write(path, to_json)
      end

      def self.load(path : String, scenario_paths : Array(String)) : State
        return new(scenario_paths) unless File.exists?(path)
        state = from_json(File.read(path))
        scenario_paths.each { |scenario| state.paths[scenario] ||= PathCount.new }
        state
      end
    end

    # The runtime-specific half of the happy rotation. This keeps provider,
    # identity, approval, and compiled-artifact policy out of the pack while
    # making their required sequencing explicit and testable.
    abstract class HappyHost(M)
      abstract def boot(root : Path, primary_run_id : String, settings : EvolutionSettings) : Chronicle::Runtime(M)

      abstract def author_service : AuthorService

      abstract def lifecycle_service(runtime : Chronicle::Runtime(M)) : LifecycleService

      # These callbacks are the verified-owner boundary. They must create the
      # corresponding approved/open ticket; the runner only applies it through
      # the normal between-frame chassis path.
      abstract def approve_adoption(runtime : Chronicle::Runtime(M), proposal : Chronicle::GraphObject) : Nil

      # The sealed compiled pack belongs to the host, so only it can exercise
      # the newly adopted behavior on the parent runtime. It must raise if the
      # behavior does not fire or if it produces an attributable failure.
      abstract def watch_happy(runtime : Chronicle::Runtime(M), proposal : Chronicle::GraphObject, promotion_id : String) : Nil

      abstract def approve_disable(runtime : Chronicle::Runtime(M), promotion_id : String, reason : String) : Nil
    end

    record HappyRotationResult,
      rotation : Int32,
      proposal_id : String,
      promotion_id : String,
      disabled_previous_promotion_id : String = "",
      reloaded : Hash(String, String) = {} of String => String

    # A single operator-visible happy rotation. It creates and retains the
    # SQLite/state workspace, starts a fresh host runtime every time, executes
    # the governed lifecycle, records the `happy` outcome, and drops all
    # graph-bound service references at teardown.
    class HappyRotation(M)
      getter root : Path
      getter state_path : Path
      getter state : State
      getter settings : EvolutionSettings

      @runtime : Chronicle::Runtime(M)?

      def initialize(@root : Path, @host : HappyHost(M), @settings : EvolutionSettings = EvolutionSettings.new(enabled: true))
        FileUtils.mkdir_p(@root)
        @state_path = @root / "state.json"
        @state = State.load(@state_path.to_s, SCENARIO_PATHS)
        @runtime = nil
      end

      # A fresh runtime per rotation makes restart/reload part of the happy
      # path rather than an afterthought. Hosts return a runtime with its base
      # packs loaded; this method attaches the Evolution host services and
      # reconciles durable promotions before authoring new work.
      def boot : Hash(String, String)
        @runtime = @host.boot(@root, @state.primary_run_id, @settings)
        runtime = current_runtime
        graph = runtime.graph || raise PackError.new("Evolution happy rotation requires an attached graph")
        Author.set_service(graph, @host.author_service)
        Lifecycle.install(graph, @host.lifecycle_service(runtime))
        reloaded = Boot.reload_adopted_packs(runtime)
        runtime.run_until_idle
        @state.primary_run_id = runtime.run_id
        reloaded
      end

      def teardown : Nil
        Author.clear_services
        Lifecycle.clear
        @runtime = nil
      end

      def author_and_gate(name : String) : Chronicle::GraphObject
        runtime = current_runtime
        graph = runtime.graph || raise PackError.new("Evolution happy rotation requires an attached graph")
        gap = graph.add_object("capability_gap", {
          "kind"        => JSON::Any.new("owner_request"),
          "description" => JSON::Any.new("soak synthetic gap for #{name}"),
          "status"      => JSON::Any.new("open"),
        }.to_json, actor: "evolution.soak")
        proposal = Author.draft_proposal(
          graph, gap.id, base_name: name, model: "host:soak",
          settings: @settings, day: Time.utc.to_s("%Y-%m-%d"), at: Time.utc.to_rfc3339,
        )
        runtime.run_until_idle
        proposal = graph.get_object(proposal.id) || raise PackError.new("gated happy proposal disappeared: #{proposal.id}")
        status = JSON.parse(proposal.data)["status"]?.try(&.as_s?) || ""
        raise PackError.new("happy candidate did not gate: #{status.inspect}") unless status == "gated"
        proposal
      end

      def approve_adoption(proposal : Chronicle::GraphObject) : Nil
        @host.approve_adoption(current_runtime, proposal)
        current_runtime.run_until_idle
      end

      def sweep : Array(Hash(String, JSON::Any))
        Chassis.sweep_evolution(current_runtime, @settings)
      end

      def scenario_happy(index : Int32) : HappyRotationResult
        runtime = current_runtime
        graph = runtime.graph || raise PackError.new("Evolution happy rotation requires an attached graph")
        proposal = author_and_gate("happy_#{index}")
        trial = Trial.run_trial(graph, proposal, @settings)
        raise PackError.new("happy candidate trial failed at #{trial.gate.inspect}") unless trial.verdict == "pass"
        proposal = graph.get_object(proposal.id) || raise PackError.new("trialed happy proposal disappeared: #{proposal.id}")
        approve_adoption(proposal)
        outcomes = sweep
        promoted = outcomes.find { |outcome| outcome["outcome"]?.try(&.as_s?) == "promoted" } ||
                   raise PackError.new("happy adoption was not promoted: #{outcomes}")
        promotion_id = promoted["promotion"].as_s
        runtime.run_until_idle
        @host.watch_happy(runtime, proposal, promotion_id)

        previous = @state.last_happy_promotion
        unless previous.empty? || previous == promotion_id
          @host.approve_disable(runtime, previous, "superseded by happy soak rotation #{index}")
          current_runtime.run_until_idle
          disable_outcomes = sweep
          unless disable_outcomes.any? { |outcome| outcome["outcome"]?.try(&.as_s?) == "disabled" }
            raise PackError.new("prior happy promotion did not disable: #{disable_outcomes}")
          end
        end
        @state.last_happy_promotion = promotion_id
        HappyRotationResult.new(index, proposal.id, promotion_id, previous)
      end

      def run_rotation : HappyRotationResult
        index = @state.rotations + 1
        reloaded = boot
        begin
          result = scenario_happy(index)
          @state.advance_rotation
          @state.record("happy", true)
          @state.save(@state_path.to_s)
          result.copy_with(reloaded: reloaded)
        rescue ex
          @state.record("happy", false)
          @state.save(@state_path.to_s)
          raise ex
        ensure
          teardown
        end
      end

      private def current_runtime : Chronicle::Runtime(M)
        @runtime || raise PackError.new("Evolution happy rotation is not booted")
      end
    end
  end
end

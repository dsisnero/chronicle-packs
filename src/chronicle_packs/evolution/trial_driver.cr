module Chronicle::Packs::Evolution
  # The chassis-owned trial driver: recorded-segment replay inside the
  # runtime's trial child (design §3 stage 3, activegraph.sandbox).
  #
  # The driver is part of the authored file set: the canonical render is
  # included verbatim as `trial_scenario.cr`, the bundle hash pins it, and the
  # `static:trial_driver` gate refuses any proposal whose copy differs byte for
  # byte. The render is deterministic — a string list and a float, nothing else
  # varies. Crystal child ABI: the file defines
  # `Chronicle::Sandbox::Scenario.run(runtime)`, which the sandbox child runner
  # requires and calls after loading the candidate pack.
  module TrialDriverConstants
    # Root-level so the child runner's `require "<basename>"` resolves via
    # CRYSTAL_PATH (which includes the candidate root).
    TRIAL_DRIVER_PATH = "trial_scenario.cr"

    DRIVER_SOURCE = <<-'CR'
    # Chassis trial driver (evolution stage 3; chassis-owned, gate-verified).
    #
    # Runs inside the runtime trial child against the fork: replays the
    # recorded segment in-sample then held-out (touched exactly once), counts
    # candidate failures per stage, sweeps the replay residue on a clean run,
    # and leaves untyped trial_stage_result markers for the parent to read
    # back. The store is the record.
    module Chronicle::Sandbox::Scenario
      extend self

      REPLAY_TYPES = __REPLAY_TYPES__
      HELDOUT_FRACTION = __HELDOUT_FRACTION__

      def run(rt : Chronicle::Runtime(M)) : Nil forall M
        graph = rt.graph || raise "trial scenario requires an attached graph"
        baseline_objects = graph.all_objects.map(&.id).to_set
        baseline_relations = graph.all_relations.map(&.id).to_set

        records = graph.all_objects
          .select { |obj| REPLAY_TYPES.includes?(obj.type) }
          .map { |obj| {type: obj.type, data: obj.data} }
        split = records.empty? ? 0 : Math.max(1, (records.size * (1 - HELDOUT_FRACTION)).to_i)

        failure_count = -> { rt.trace.failures.size }

        replay = ->(segment : Array({type: String, data: String})) do
          segment.each do |record|
            graph.add_object(record[:type], record[:data])
            rt.run_until_idle
          end
        end

        stages = [] of {String, Int32, Int32}
        replay.call(records[0...split])
        in_sample_failures = failure_count.call
        stages << {"in_sample", split, in_sample_failures}
        if in_sample_failures == 0 && records.size > split
          replay.call(records[split..])
          stages << {"held_out", records.size - split, failure_count.call - in_sample_failures}
        end

        swept_objects = 0
        swept_relations = 0
        if failure_count.call == 0
          new_objects = graph.all_objects.reject { |obj| baseline_objects.includes?(obj.id) }
          new_relations = graph.all_relations.reject { |rel| baseline_relations.includes?(rel.id) }
          new_objects.each { |obj| graph.remove_object(obj.id) }
          new_relations.each { |rel| graph.remove_relation(rel.id) }
          swept_objects = new_objects.size
          swept_relations = new_relations.size
        end

        stages.each do |stage, inputs, failures|
          graph.add_object("trial_stage_result", {"stage" => stage, "inputs" => inputs, "failures" => failures}.to_json)
        end
        graph.add_object("trial_stage_result", {"stage" => "sweep", "objects" => swept_objects, "relations" => swept_relations}.to_json)
      end
    end
    CR
  end

  # Crystal `Array(String)` literal for the render.
  def self._crystal_list_repr(items : Array(String)) : String
    "[" + items.map(&.to_json).join(", ") + "] of String"
  end

  # The canonical driver bytes for the given settings.
  def self.render_trial_driver(settings : EvolutionSettings? = nil) : String
    s = settings || EvolutionSettings.new
    TrialDriverConstants::DRIVER_SOURCE
      .gsub("__REPLAY_TYPES__", _crystal_list_repr(s.replay_object_types))
      .gsub("__HELDOUT_FRACTION__", s.heldout_fraction.to_s)
  end
end

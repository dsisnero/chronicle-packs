module Chronicle::Packs::Evolution
  # The chassis-owned trial driver: recorded-segment replay inside the
  # runtime's trial child (design §3 stage 3, activegraph.sandbox).
  #
  # The driver is part of the authored file set: authors include
  # `fixtures/trial_scenario.py` verbatim, the bundle hash pins it, and the
  # `static:trial_driver` gate refuses any proposal whose copy differs byte
  # for byte from the canonical render below. The render is deterministic —
  # a string list and a float, nothing else varies.
  module TrialDriverConstants
    TRIAL_DRIVER_PATH = "fixtures/trial_scenario.py"

    DRIVER_SOURCE = <<-PY
    """Chassis trial driver (evolution stage 3; chassis-owned, gate-verified).

    Runs inside the runtime trial child against the fork: replays the
    recorded segment in-sample then held-out (touched exactly once), counts
    candidate failures per stage, sweeps the replay residue on a clean run,
    and leaves untyped trial_stage_result markers for the parent to read
    back. The store is the record."""

    REPLAY_TYPES = __REPLAY_TYPES__
    HELDOUT_FRACTION = __HELDOUT_FRACTION__


    def main(rt):
        graph = rt.graph
        baseline_objects = set(o.id for o in graph.all_objects())
        baseline_relations = set(r.id for r in graph.all_relations())
        records = [
            {"type": o.type, "data": dict(o.data or {})}
            for o in graph.all_objects()
            if o.type in REPLAY_TYPES
        ]
        split = max(1, int(len(records) * (1 - HELDOUT_FRACTION))) if records else 0

        def replay(segment):
            for record in segment:
                graph.add_object(record["type"], record["data"])
                rt.run_until_idle()

        def failure_count():
            return len(list(rt.trace.failures()))

        stages = []
        replay(records[:split])
        in_sample_failures = failure_count()
        stages.append(("in_sample", split, in_sample_failures))
        if in_sample_failures == 0 and records[split:]:
            replay(records[split:])
            stages.append(("held_out", len(records) - split,
                           failure_count() - in_sample_failures))

        swept_objects = 0
        swept_relations = 0
        if failure_count() == 0:
            new_objects = [o for o in graph.all_objects()
                           if o.id not in baseline_objects]
            new_relations = [r for r in graph.all_relations()
                             if r.id not in baseline_relations]
            for obj in new_objects:
                graph.remove_object(obj.id)
            for rel in graph.all_relations():
                if rel.id not in baseline_relations:
                    graph.remove_relation(rel.id)
            swept_objects = len(new_objects)
            swept_relations = len(new_relations)

        for stage, inputs, failures in stages:
            graph.add_object("trial_stage_result", {
                "stage": stage, "inputs": inputs, "failures": failures,
            })
        graph.add_object("trial_stage_result", {
            "stage": "sweep", "objects": swept_objects,
            "relations": swept_relations,
        })
    PY
  end

  # Python `repr(list[str])`: single-quoted strings (upstream render).
  def self._py_list_repr(items : Array(String)) : String
    "[" + items.map { |item| "'" + item.gsub("\\", "\\\\").gsub("'", "\\'") + "'" }.join(", ") + "]"
  end

  # The canonical driver bytes for the given settings.
  def self.render_trial_driver(settings : EvolutionSettings? = nil) : String
    s = settings || EvolutionSettings.new
    TrialDriverConstants::DRIVER_SOURCE
      .gsub("__REPLAY_TYPES__", _py_list_repr(s.replay_object_types))
      .gsub("__HELDOUT_FRACTION__", s.heldout_fraction.to_s)
  end
end

module Chronicle::Packs::Schedule
  # Schedule Pack relation types. Ported from upstream
  # packs/schedule/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "tick_of", source_types: ["schedule_tick"], target_types: ["schedule"], description: "A tick satisfies a due moment of its schedule.")]
  struct TickOf
  end

  # Source open (empty = any): a schedule may emit any declared object type.
  @[Chronicle::Packs::Annotations::RelationType(name: "emitted_by", source_types: [] of String, target_types: ["schedule"], description: "An object was emitted by a schedule's tick (payload instantiation).")]
  struct EmittedBy
  end
end

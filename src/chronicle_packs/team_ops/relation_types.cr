module Chronicle::Packs::TeamOps
  # Team/Ops Pack relation types. Ported from upstream
  # packs/team_ops/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "assigned_to", source_types: ["assignment"], target_types: ["task"], description: "Assignment links to the Core task.")]
  struct AssignedTo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "depends_on", source_types: ["task"], target_types: ["task"], description: "Task depends on another task.")]
  struct DependsOn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "part_of_milestone", source_types: ["task"], target_types: ["milestone"], description: "Task is part of a Milestone.")]
  struct PartOfMilestone
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "part_of_project", source_types: ["task", "milestone"], target_types: ["project"], description: "Task or Milestone is part of a Project.")]
  struct PartOfProject
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "evidence_for", source_types: ["completion_evidence"], target_types: ["task"], description: "Evidence for task completion.")]
  struct EvidenceFor
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "review_of", source_types: ["review_request"], target_types: ["task"], description: "ReviewRequest is for a task.")]
  struct ReviewOf
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "workload_for", source_types: ["workload_estimate"], target_types: ["assignment"], description: "WorkloadEstimate associated with an Assignment.")]
  struct WorkloadFor
  end
end

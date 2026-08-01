module Chronicle::Packs::Core
  # The 7 (well, 8 — the manifest declares 8 names) relation types of the
  # Core pack. `source_types` / `target_types` constrain the endpoints;
  # empty means "any". Ported from upstream packs/core/object_types.py.
  #
  # The structs themselves are empty — the DSL collects the relation
  # metadata from the annotations; there is no relation data schema.

  # A source grounds (provides evidence for) an observation.
  @[Chronicle::Packs::Annotations::RelationType(name: "grounds", source_types: ["source"], target_types: ["observation"])]
  struct Grounds
  end

  # An observation produces a downstream object.
  @[Chronicle::Packs::Annotations::RelationType(name: "produces", source_types: ["observation"], target_types: ["task", "action", "artifact", "memory_candidate"])]
  struct Produces
  end

  # An action executes (fulfills) a task.
  @[Chronicle::Packs::Annotations::RelationType(name: "executes", source_types: ["action"], target_types: ["task"])]
  struct Executes
  end

  # A task or action generates an artifact.
  @[Chronicle::Packs::Annotations::RelationType(name: "generates", source_types: ["task", "action"], target_types: ["artifact"])]
  struct Generates
  end

  # An observation or action proposes a memory candidate.
  @[Chronicle::Packs::Annotations::RelationType(name: "proposes", source_types: ["observation", "action"], target_types: ["memory_candidate"])]
  struct Proposes
  end

  # An evaluation judges a subject object.
  @[Chronicle::Packs::Annotations::RelationType(name: "evaluates", source_types: ["evaluation"], target_types: ["memory_candidate", "artifact", "action", "task", "observation"])]
  struct Evaluates
  end

  # A downstream object is derived from a source object. Target is open on
  # purpose (empty = any): bridge packs point derived_from at domain
  # objects Core must not enumerate (Core stays small).
  @[Chronicle::Packs::Annotations::RelationType(name: "derived_from", source_types: ["source", "observation", "task", "action", "artifact", "memory_candidate", "evaluation"])]
  struct DerivedFrom
  end

  # A domain or infrastructure object is derived from a Core source.
  # Universal provenance relation, declared here so all packs share one
  # definition.
  @[Chronicle::Packs::Annotations::RelationType(name: "derived_from_source", source_types: ["observation", "task", "action", "artifact", "memory_candidate", "evaluation", "comm_message", "comm_thread", "comm_intent", "comm_response_candidate", "paper", "meeting", "transcript_segment", "repo", "issue", "pull_request", "architecture_decision", "code_change", "test_result", "company_profile", "founder_profile", "investment_memo", "deal_round", "email_message", "email_thread", "email_draft", "chat_input", "chat_session", "chat_turn"], target_types: ["source"])]
  struct DerivedFromSource
  end
end

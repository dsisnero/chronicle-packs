module Chronicle::Packs::Research
  # Research Pack relation types. Ported from upstream
  # packs/research/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "cites", source_types: ["paper"], target_types: ["paper"], description: "Paper A cites Paper B.")]
  struct Cites
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "authored_by", source_types: ["paper"], target_types: ["author"], description: "Paper authored by an Author.")]
  struct AuthoredBy
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "published_in", source_types: ["paper"], target_types: ["venue"], description: "Paper published in a Venue.")]
  struct PublishedIn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "uses_method", source_types: ["paper"], target_types: ["method"], description: "Paper uses a Method.")]
  struct UsesMethod
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "reports_benchmark", source_types: ["paper"], target_types: ["benchmark"], description: "Paper reports results on a Benchmark.")]
  struct ReportsBenchmark
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "uses_dataset", source_types: ["paper"], target_types: ["dataset"], description: "Paper uses a Dataset.")]
  struct UsesDataset
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "proposes_idea", source_types: ["paper"], target_types: ["idea_atom"], description: "Paper proposes or implies an IdeaAtom.")]
  struct ProposesIdea
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "composes_direction", source_types: ["idea_atom"], target_types: ["research_direction"], description: "IdeaAtom contributes to a ResearchDirection.")]
  struct ComposesDirection
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "tests_direction", source_types: ["experiment"], target_types: ["research_direction"], description: "Experiment tests a ResearchDirection hypothesis.")]
  struct TestsDirection
  end
end

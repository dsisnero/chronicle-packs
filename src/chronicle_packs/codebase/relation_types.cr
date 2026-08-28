module Chronicle::Packs::Codebase
  # Codebase Pack relation types. Ported from upstream
  # packs/codebase/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "file_in_repo", source_types: ["code_file"], target_types: ["repo"], description: "File belongs to a Repo.")]
  struct FileInRepo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "function_in_file", source_types: ["code_function"], target_types: ["code_file"], description: "Function defined in a CodeFile.")]
  struct FunctionInFile
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "repo_depends_on", source_types: ["repo"], target_types: ["dependency"], description: "Repo declares a Dependency.")]
  struct RepoDependsOn
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "issue_in_repo", source_types: ["issue"], target_types: ["repo"], description: "Issue belongs to a Repo.")]
  struct IssueInRepo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "pr_in_repo", source_types: ["pull_request"], target_types: ["repo"], description: "PR belongs to a Repo.")]
  struct PrInRepo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "adr_in_repo", source_types: ["architecture_decision"], target_types: ["repo"], description: "ADR belongs to a Repo.")]
  struct AdrInRepo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "change_in_repo", source_types: ["code_change"], target_types: ["repo"], description: "CodeChange belongs to a Repo.")]
  struct ChangeInRepo
  end

  @[Chronicle::Packs::Annotations::RelationType(name: "test_for_repo", source_types: ["test_result"], target_types: ["repo"], description: "TestResult belongs to a Repo.")]
  struct TestForRepo
  end
end

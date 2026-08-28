require "json"

module Chronicle::Packs::Codebase
  # Codebase Pack object types. Ported from upstream packs/codebase/
  # object_types.py. 9 object types for engineering workflow visibility.

  # Closed Literal sets for the codebase surface (AGENTS.md: closed string
  # sets are enums; non-flags enums round-trip via the underscore name).

  # Dependency.kind — upstream Literal["direct", "transitive", "dev", "peer"].
  enum DependencyKind
    Direct
    Transitive
    Dev
    Peer
  end

  # Issue.state — upstream Literal["open", "closed"].
  enum IssueState
    Open
    Closed
  end

  # PullRequest.state — upstream Literal["open", "closed", "merged"].
  enum PullRequestState
    Open
    Closed
    Merged
  end

  # ArchitectureDecision.status — upstream Literal["proposed", "accepted",
  # "deprecated", "superseded"].
  enum AdrStatus
    Proposed
    Accepted
    Deprecated
    Superseded
  end

  # A code repository.
  @[Chronicle::Packs::Annotations::ObjectType(name: "repo", description: "A code repository.")]
  struct Repo
    include JSON::Serializable

    getter name : String
    getter full_name : String = ""
    getter description : String = ""
    getter url : String? = nil
    getter default_branch : String = "main"
    getter language : String? = nil
    getter stars : Int32 = 0
    getter open_issues_count : Int32 = 0
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @name : String,
      @full_name : String = "",
      @description : String = "",
      @url : String? = nil,
      @default_branch : String = "main",
      @language : String? = nil,
      @stars : Int32 = 0,
      @open_issues_count : Int32 = 0,
      @source_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A file within a repo.
  @[Chronicle::Packs::Annotations::ObjectType(name: "code_file", description: "A file within a repo.")]
  struct CodeFile
    include JSON::Serializable

    getter repo_id : String
    getter path : String
    getter language : String? = nil
    getter line_count : Int32 = 0
    getter content_summary : String = ""
    getter last_modified_at : String? = nil
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A function or method within a file.
  @[Chronicle::Packs::Annotations::ObjectType(name: "code_function", description: "A function or method within a file.")]
  struct CodeFunction
    include JSON::Serializable

    getter file_id : String
    getter name : String
    getter signature : String = ""
    getter docstring : String = ""
    getter line_start : Int32? = nil
    getter line_end : Int32? = nil
    getter complexity_score : Float64? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A package dependency declared in a repo.
  @[Chronicle::Packs::Annotations::ObjectType(name: "dependency", description: "A package dependency declared in a repo.")]
  struct Dependency
    include JSON::Serializable

    getter repo_id : String
    getter name : String
    getter version : String? = nil
    getter kind : DependencyKind = DependencyKind::Direct
    getter ecosystem : String = ""
    getter? has_known_vulnerability : Bool = false
    getter vulnerability_summary : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @repo_id : String,
      @name : String,
      @version : String? = nil,
      @kind : DependencyKind = DependencyKind::Direct,
      @ecosystem : String = "",
      @has_known_vulnerability : Bool = false,
      @vulnerability_summary : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A GitHub/GitLab issue.
  @[Chronicle::Packs::Annotations::ObjectType(name: "issue", description: "A GitHub/GitLab issue.")]
  struct Issue
    include JSON::Serializable

    getter repo_id : String
    getter issue_number : Int32
    getter title : String
    getter body : String = ""
    getter state : IssueState = IssueState::Open
    getter labels : Array(String) = [] of String
    getter author_ref : String? = nil
    getter assignee_refs : Array(String) = [] of String
    getter created_at : String? = nil
    getter closed_at : String? = nil
    getter source_id : String? = nil
    getter task_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @repo_id : String,
      @issue_number : Int32,
      @title : String,
      @body : String = "",
      @state : IssueState = IssueState::Open,
      @labels : Array(String) = [] of String,
      @author_ref : String? = nil,
      @assignee_refs : Array(String) = [] of String,
      @created_at : String? = nil,
      @closed_at : String? = nil,
      @source_id : String? = nil,
      @task_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A pull request.
  @[Chronicle::Packs::Annotations::ObjectType(name: "pull_request", description: "A pull request.")]
  struct PullRequest
    include JSON::Serializable

    getter repo_id : String
    getter pr_number : Int32
    getter title : String
    getter body : String = ""
    getter state : PullRequestState = PullRequestState::Open
    getter author_ref : String? = nil
    getter base_branch : String = "main"
    getter head_branch : String = ""
    getter labels : Array(String) = [] of String
    getter created_at : String? = nil
    getter merged_at : String? = nil
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # An Architecture Decision Record (ADR).
  @[Chronicle::Packs::Annotations::ObjectType(name: "architecture_decision", description: "An Architecture Decision Record (ADR).")]
  struct ArchitectureDecision
    include JSON::Serializable

    getter repo_id : String
    getter title : String
    getter context : String = ""
    getter decision : String = ""
    getter consequences : String = ""
    getter status : AdrStatus = AdrStatus::Proposed
    getter adr_number : Int32? = nil
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @repo_id : String,
      @title : String,
      @context : String = "",
      @decision : String = "",
      @consequences : String = "",
      @status : AdrStatus = AdrStatus::Proposed,
      @adr_number : Int32? = nil,
      @source_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A code change (commit or PR diff summary).
  @[Chronicle::Packs::Annotations::ObjectType(name: "code_change", description: "A code change (commit or PR diff summary).")]
  struct CodeChange
    include JSON::Serializable

    getter repo_id : String
    getter summary : String
    getter files_changed : Array(String) = [] of String
    getter lines_added : Int32 = 0
    getter lines_removed : Int32 = 0
    getter commit_sha : String? = nil
    getter pr_id : String? = nil
    getter author_ref : String? = nil
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @repo_id : String,
      @summary : String,
      @files_changed : Array(String) = [] of String,
      @lines_added : Int32 = 0,
      @lines_removed : Int32 = 0,
      @commit_sha : String? = nil,
      @pr_id : String? = nil,
      @author_ref : String? = nil,
      @source_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A test run result.
  @[Chronicle::Packs::Annotations::ObjectType(name: "test_result", description: "A test run result.")]
  struct TestResult
    include JSON::Serializable

    getter repo_id : String
    getter suite_name : String
    getter passed : Int32 = 0
    getter failed : Int32 = 0
    getter skipped : Int32 = 0
    getter coverage_pct : Float64? = nil
    getter run_at : String? = nil
    getter commit_sha : String? = nil
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

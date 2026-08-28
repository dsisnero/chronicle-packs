require "json"

module Chronicle::Packs::TeamOps
  # Team/Ops Pack object types. Ported from upstream packs/team_ops/
  # object_types.py. 6 project-management primitives extending Core task.

  # Closed Literal sets for the team_ops surface (AGENTS.md: closed string
  # sets are enums; non-flags enums round-trip via the underscore name).

  # Project.status — upstream Literal["planning", "active", "on_hold",
  # "completed", "cancelled"].
  enum ProjectStatus
    Planning
    Active
    OnHold
    Completed
    Cancelled
  end

  # Milestone.status — upstream Literal["upcoming", "in_progress",
  # "completed", "missed"].
  enum MilestoneStatus
    Upcoming
    InProgress
    Completed
    Missed
  end

  # ReviewRequest.review_type — upstream Literal["code_review",
  # "design_review", "content_review", "approval"].
  enum ReviewType
    CodeReview
    DesignReview
    ContentReview
    Approval
  end

  # ReviewRequest.status — upstream Literal["pending", "in_review",
  # "approved", "rejected", "cancelled"].
  enum ReviewStatus
    Pending
    InReview
    Approved
    Rejected
    Cancelled
  end

  # A project grouping tasks and milestones.
  @[Chronicle::Packs::Annotations::ObjectType(name: "project", description: "A project grouping tasks and milestones.")]
  struct Project
    include JSON::Serializable

    getter name : String
    getter description : String = ""
    getter status : ProjectStatus = ProjectStatus::Planning
    getter owner_ref : String? = nil
    getter goal : String = ""
    getter start_date : String? = nil
    getter target_date : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @name : String,
      @description : String = "",
      @status : ProjectStatus = ProjectStatus::Planning,
      @owner_ref : String? = nil,
      @goal : String = "",
      @start_date : String? = nil,
      @target_date : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Assignment of a task to a principal.
  @[Chronicle::Packs::Annotations::ObjectType(name: "assignment", description: "Assignment of a task to a principal.")]
  struct Assignment
    include JSON::Serializable

    getter task_id : String
    getter principal_ref : String
    getter role : String = "assignee"
    getter assigned_at : String? = nil
    getter workload_estimate_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @task_id : String,
      @principal_ref : String,
      @role : String = "assignee",
      @assigned_at : String? = nil,
      @workload_estimate_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A milestone grouping tasks with a target date.
  @[Chronicle::Packs::Annotations::ObjectType(name: "milestone", description: "A milestone grouping tasks with a target date.")]
  struct Milestone
    include JSON::Serializable

    getter project_id : String
    getter title : String
    getter description : String = ""
    getter target_date : String? = nil
    getter status : MilestoneStatus = MilestoneStatus::Upcoming
    getter task_ids : Array(String) = [] of String
    getter completion_pct : Float64 = 0.0
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @project_id : String,
      @title : String,
      @description : String = "",
      @target_date : String? = nil,
      @status : MilestoneStatus = MilestoneStatus::Upcoming,
      @task_ids : Array(String) = [] of String,
      @completion_pct : Float64 = 0.0,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # Estimated workload for a principal in a period.
  @[Chronicle::Packs::Annotations::ObjectType(name: "workload_estimate", description: "Estimated workload for a principal in a period.")]
  struct WorkloadEstimate
    include JSON::Serializable

    getter principal_ref : String
    getter period : String = ""
    getter estimated_hours : Float64 = 0.0
    getter committed_hours : Float64 = 0.0
    getter capacity_hours : Float64 = 40.0
    getter? overloaded : Bool = false
    getter task_ids : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Evidence that a task was completed.
  @[Chronicle::Packs::Annotations::ObjectType(name: "completion_evidence", description: "Evidence that a task was completed.")]
  struct CompletionEvidence
    include JSON::Serializable

    getter task_id : String
    getter evidence_text : String
    getter completed_by_ref : String? = nil
    getter completed_at : String? = nil
    getter source_ids : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @task_id : String,
      @evidence_text : String,
      @completed_by_ref : String? = nil,
      @completed_at : String? = nil,
      @source_ids : Array(String) = [] of String,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A request for review of a task or artifact.
  @[Chronicle::Packs::Annotations::ObjectType(name: "review_request", description: "A request for review of a task or artifact.")]
  struct ReviewRequest
    include JSON::Serializable

    getter task_id : String
    getter requested_by_ref : String
    getter reviewer_ref : String
    getter review_type : ReviewType = ReviewType::Approval
    getter status : ReviewStatus = ReviewStatus::Pending
    getter notes : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @task_id : String,
      @requested_by_ref : String,
      @reviewer_ref : String,
      @review_type : ReviewType = ReviewType::Approval,
      @status : ReviewStatus = ReviewStatus::Pending,
      @notes : String = "",
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

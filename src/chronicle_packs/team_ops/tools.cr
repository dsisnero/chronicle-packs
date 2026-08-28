require "json"
require "time"

module Chronicle::Packs::TeamOps
  # Team/Ops Pack tools. Ported from upstream packs/team_ops/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Create a Project.
  def self.create_project_fn(
    graph : Chronicle::GraphProjection,
    name : String,
    description : String = "",
    goal : String = "",
    owner_ref : String? = nil,
    start_date : String? = nil,
    target_date : String? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("project", Project.new(
      name: name,
      description: description,
      goal: goal,
      status: ProjectStatus::Planning,
      owner_ref: owner_ref,
      start_date: start_date,
      target_date: target_date,
    ).to_json, actor: "team_ops")
  end

  # Create a Milestone linked to a Project.
  def self.create_milestone_fn(
    graph : Chronicle::GraphProjection,
    project_id : String,
    title : String,
    description : String = "",
    target_date : String? = nil,
  ) : Chronicle::GraphObject
    ms = graph.add_object("milestone", Milestone.new(
      project_id: project_id,
      title: title,
      description: description,
      target_date: target_date,
      status: MilestoneStatus::Upcoming,
      task_ids: [] of String,
      completion_pct: 0.0,
    ).to_json, actor: "team_ops")
    begin
      graph.add_relation(ms.id, project_id, "part_of_project", actor: "team_ops")
    rescue
    end
    ms
  end

  # Create a task_candidate observation that task_triager will promote.
  def self.submit_task_candidate_fn(
    graph : Chronicle::GraphProjection,
    text : String,
    owner_ref : String? = nil,
    project_id : String? = nil,
    milestone_id : String? = nil,
    priority : String = "medium",
  ) : Chronicle::GraphObject
    graph.add_object("observation", {
      "text"       => JSON::Any.new(text),
      "confidence" => JSON::Any.new(0.85),
      "category"   => JSON::Any.new("task_candidate"),
      "metadata"   => JSON::Any.new({
        "task_candidate" => JSON::Any.new(true),
        "owner_ref"      => JSON::Any.new(owner_ref),
        "project_id"     => JSON::Any.new(project_id),
        "milestone_id"   => JSON::Any.new(milestone_id),
        "priority"       => JSON::Any.new(priority),
      }),
    }.to_json, actor: "team_ops")
  end

  # Directly create an Assignment for a task.
  def self.assign_task_fn(
    graph : Chronicle::GraphProjection,
    task_id : String,
    principal_ref : String,
    role : String = "assignee",
  ) : Chronicle::GraphObject
    assignment = graph.add_object("assignment", Assignment.new(
      task_id: task_id,
      principal_ref: principal_ref,
      role: role,
      assigned_at: _now_iso,
    ).to_json, actor: "team_ops")
    begin
      graph.add_relation(assignment.id, task_id, "assigned_to", actor: "team_ops")
    rescue
    end
    assignment
  end

  # Create CompletionEvidence and mark the task as done.
  def self.mark_task_done_fn(
    graph : Chronicle::GraphProjection,
    task_id : String,
    evidence_text : String,
    completed_by_ref : String? = nil,
  ) : Chronicle::GraphObject
    now = _now_iso
    evidence = graph.add_object("completion_evidence", CompletionEvidence.new(
      task_id: task_id,
      evidence_text: evidence_text,
      completed_by_ref: completed_by_ref,
      completed_at: now,
    ).to_json, actor: "team_ops")
    begin
      graph.add_relation(evidence.id, task_id, "evidence_for", actor: "team_ops")
    rescue
    end
    begin
      graph.patch_object(task_id, {"status" => JSON::Any.new("done")}.to_json, actor: "team_ops")
    rescue
    end
    evidence
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "team_ops tools require a bound graph (set TeamOps.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "create_project", description: "Create a project to group tasks and milestones.", deterministic: true)]
  def create_project_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = create_project_fn(
      bound_graph_or_raise,
      input["name"]?.try(&.as_s?) || "",
      description: input["description"]?.try(&.as_s?) || "",
      goal: input["goal"]?.try(&.as_s?) || "",
      owner_ref: input["owner_ref"]?.try(&.as_s?),
      start_date: input["start_date"]?.try(&.as_s?),
      target_date: input["target_date"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_milestone", description: "Create a milestone within a project.", deterministic: true)]
  def create_milestone_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = create_milestone_fn(
      bound_graph_or_raise,
      input["project_id"]?.try(&.as_s?) || "",
      input["title"]?.try(&.as_s?) || "",
      description: input["description"]?.try(&.as_s?) || "",
      target_date: input["target_date"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "submit_task_candidate", description: "Submit a task candidate for triage.", deterministic: true)]
  def submit_task_candidate_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = submit_task_candidate_fn(
      bound_graph_or_raise,
      input["text"]?.try(&.as_s?) || "",
      owner_ref: input["owner_ref"]?.try(&.as_s?),
      project_id: input["project_id"]?.try(&.as_s?),
      milestone_id: input["milestone_id"]?.try(&.as_s?),
      priority: input["priority"]?.try(&.as_s?) || "medium",
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "assign_task", description: "Assign a task to a team member.", deterministic: true)]
  def assign_task_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = assign_task_fn(
      bound_graph_or_raise,
      input["task_id"]?.try(&.as_s?) || "",
      input["principal_ref"]?.try(&.as_s?) || "",
      role: input["role"]?.try(&.as_s?) || "assignee",
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "mark_task_done", description: "Mark a task as done with completion evidence.", deterministic: true)]
  def mark_task_done_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = mark_task_done_fn(
      bound_graph_or_raise,
      input["task_id"]?.try(&.as_s?) || "",
      input["evidence_text"]?.try(&.as_s?) || "",
      completed_by_ref: input["completed_by_ref"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end
end

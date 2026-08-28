require "json"
require "time"

module Chronicle::Packs::TeamOps
  # Team/Ops Pack behaviors. Ported from upstream packs/team_ops/behaviors.py.
  #
  # task_triager         — observation.created (task_candidate hint) → Core
  #                        task + optional Assignment
  # assignment_suggester — task.created → Assignment (if auto_assign_tasks)
  # milestone_tracker    — milestone.created → open-milestone registries
  # completion_verifier  — observation.created (done/completed) →
  #                        CompletionEvidence + task status→done
  #
  # Design: TeamTask wraps the Core task via relations, not a separate
  # object type. Assignment links a Core task to a principal.
  #
  # Registries (class-level, cleared between fixtures via
  # clear_team_ops_registry):
  #   project_milestone_registry: project_id → [milestone_id, ...]
  #   task_assignments:           task_id → assignment_id
  #   open_milestones:            milestone_id → {project_id, title, status}

  # project_id → [milestone_id, ...].
  class_property project_milestone_registry = {} of String => Array(String)
  # task_id → assignment_id.
  class_property task_assignments = {} of String => String
  # milestone_id → {project_id, title, status}.
  class_property open_milestones = {} of String => Hash(String, JSON::Any)

  # Reset all registries — call between test fixtures.
  def self.clear_team_ops_registry : Nil
    self.project_milestone_registry = {} of String => Array(String)
    self.task_assignments = {} of String => String
    self.open_milestones = {} of String => Hash(String, JSON::Any)
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Jaccard word-set overlap between two strings (upstream _word_overlap).
  def self._word_overlap(a : String, b : String) : Float64
    stopwords = Set{"a", "an", "the", "and", "or", "in", "on", "to", "for", "of", "is", "be"}
    wa = a.downcase.scan(/[a-z]+/).map(&.[0]).to_set.reject { |word| stopwords.includes?(word) || word.size <= 2 }
    wb = b.downcase.scan(/[a-z]+/).map(&.[0]).to_set.reject { |word| stopwords.includes?(word) || word.size <= 2 }
    return 0.0 if wa.empty? || wb.empty?
    (wa & wb).size.to_f / (wa | wb).size
  end

  # Extract an owner ref from assign-to/owner: patterns (upstream
  # _extract_owner_from_text).
  def self._extract_owner_from_text(text : String) : String?
    match = text.scan(/(?:assign(?:ed)? to|owner:|@)([A-Za-z0-9._+@-]+)/i).first?
    match.try(&.[1]?).try(&.strip)
  end

  # Promote task_candidate observations to Core tasks.
  @[Chronicle::Packs::Annotations::Behavior(name: "task_triager", on: ["object.created"], where: {"type" => "observation"}, creates: ["task", "assignment"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream task_triager candidate/assign branches
  def task_triager(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TeamOpsSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    obs_id = payload["id"]?.try(&.as_s?)
    return if obs_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    category = data["category"]?.try(&.as_s?) || ""
    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    is_task_candidate =
      category == settings.task_candidate_hint ||
        meta["task_candidate"]?.try(&.as_bool?) == true ||
        category == "action_item"

    return unless is_task_candidate

    text = data["text"]?.try(&.as_s?) || ""
    owner_ref = _extract_owner_from_text(text) || meta["owner_ref"]?.try(&.as_s?)
    project_id = meta["project_id"]?.try(&.as_s?)
    milestone_id = meta["milestone_id"]?.try(&.as_s?)
    priority = meta["priority"]?.try(&.as_s?) || "medium"

    begin
      task = graph.add_object("task", {
        "title"                  => JSON::Any.new(text[0, 80]),
        "description"            => JSON::Any.new(text),
        "status"                 => JSON::Any.new("candidate"),
        "priority"               => JSON::Any.new(priority),
        "owner_ref"              => JSON::Any.new(owner_ref),
        "source_observation_ids" => JSON::Any.new([JSON::Any.new(obs_id)]),
      }.to_json, actor: "team_ops.task_triager")
      task_id = task.id

      if project_id
        begin
          graph.add_relation(task_id, project_id, "part_of_project", actor: "team_ops.task_triager")
        rescue
        end
      end

      if milestone_id
        begin
          graph.add_relation(task_id, milestone_id, "part_of_milestone", actor: "team_ops.task_triager")
        rescue
        end
      end

      if owner_ref && settings.auto_assign_tasks?
        begin
          assignment = graph.add_object("assignment", Assignment.new(
            task_id: task_id,
            principal_ref: owner_ref,
            role: "assignee",
            assigned_at: _now_iso,
          ).to_json, actor: "team_ops.task_triager")
          graph.add_relation(assignment.id, task_id, "assigned_to", actor: "team_ops.task_triager")
          task_assignments[task_id] = assignment.id
        rescue
        end
      end
    rescue
    end
  end

  # Create an Assignment for newly created tasks when auto_assign is enabled.
  @[Chronicle::Packs::Annotations::Behavior(name: "assignment_suggester", on: ["object.created"], where: {"type" => "task"}, creates: ["assignment"])]
  def assignment_suggester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TeamOpsSettings) : Nil
    return unless settings.auto_assign_tasks?

    payload = JSON.parse(event.payload).as_h
    task_id = payload["id"]?.try(&.as_s?)
    return if task_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return if task_assignments.has_key?(task_id)

    owner_ref = data["owner_ref"]?.try(&.as_s?)
    return if owner_ref.nil?

    priority = data["priority"]?.try(&.as_s?) || "medium"
    review_needed = settings.require_review_for_critical_tasks? && priority == "critical"

    begin
      assignment = graph.add_object("assignment", Assignment.new(
        task_id: task_id,
        principal_ref: owner_ref,
        role: "assignee",
        assigned_at: _now_iso,
      ).to_json, actor: "team_ops.assignment_suggester")
      graph.add_relation(assignment.id, task_id, "assigned_to", actor: "team_ops.assignment_suggester")
      task_assignments[task_id] = assignment.id

      if review_needed
        begin
          graph.add_object("review_request", ReviewRequest.new(
            task_id: task_id,
            requested_by_ref: "system",
            reviewer_ref: owner_ref,
            review_type: ReviewType::Approval,
            status: ReviewStatus::Pending,
            notes: "Auto-created for critical priority task.",
          ).to_json, actor: "team_ops.assignment_suggester")
        rescue
        end
      end
    rescue
    end
  end

  # Track open milestones for efficient task linking.
  @[Chronicle::Packs::Annotations::Behavior(name: "milestone_tracker", on: ["object.created"], where: {"type" => "milestone"}, creates: [] of String)]
  def milestone_tracker(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TeamOpsSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    milestone_id = payload["id"]?.try(&.as_s?)
    return if milestone_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    project_id = data["project_id"]?.try(&.as_s?) || ""
    title = data["title"]?.try(&.as_s?) || ""
    status = data["status"]?.try(&.as_s?) || "upcoming"

    if {"upcoming", "in_progress"}.includes?(status)
      open_milestones[milestone_id] = {
        "project_id" => JSON::Any.new(project_id),
        "title"      => JSON::Any.new(title),
        "status"     => JSON::Any.new(status),
      }
      if !project_id.empty?
        if !project_milestone_registry.has_key?(project_id)
          project_milestone_registry[project_id] = [] of String
        end
        if !project_milestone_registry[project_id].includes?(milestone_id)
          project_milestone_registry[project_id] << milestone_id
        end
      end
    end
  end

  # Create CompletionEvidence when a 'done' observation references a task.
  @[Chronicle::Packs::Annotations::Behavior(name: "completion_verifier", on: ["object.created"], where: {"type" => "observation"}, creates: ["completion_evidence"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream completion_verifier category/keyword/task branches
  def completion_verifier(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TeamOpsSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    obs_id = payload["id"]?.try(&.as_s?)
    return if obs_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    category = data["category"]?.try(&.as_s?) || ""
    return unless {"decision", "fact"}.includes?(category)

    text = (data["text"]?.try(&.as_s?) || "").downcase
    return unless {"completed", "done", "finished", "closed", "resolved"}.any? { |word| text.includes?(word) }

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    task_id = meta["task_id"]?.try(&.as_s?)
    return if task_id.nil?

    completed_by = meta["completed_by_ref"]?.try(&.as_s?)
    source_ids = data["source_ids"]?.try(&.as_a?) ? data["source_ids"].as_a.map(&.as_s) : [] of String

    begin
      evidence = graph.add_object("completion_evidence", CompletionEvidence.new(
        task_id: task_id,
        evidence_text: data["text"]?.try(&.as_s?) || "",
        completed_by_ref: completed_by,
        completed_at: _now_iso,
        source_ids: source_ids,
      ).to_json, actor: "team_ops.completion_verifier")
      graph.add_relation(evidence.id, task_id, "evidence_for", actor: "team_ops.completion_verifier")

      begin
        graph.patch_object(task_id, {"status" => JSON::Any.new("done")}.to_json, actor: "team_ops.completion_verifier")
      rescue
      end
    rescue
    end
  end
end

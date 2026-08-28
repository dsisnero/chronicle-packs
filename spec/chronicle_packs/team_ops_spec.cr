require "spec"
require "../spec_helper"

# Team/Ops Pack (packs/team_ops): task triage, assignment, milestone
# tracking, workload estimation, completion verification. Translated from
# upstream packs/team_ops/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Extends Core task; TeamTask
# wraps Core task via relations rather than a separate object type.

module TeamOpsSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def team_ops_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "team_ops" / "manifest.toml"
  end

  # Mirrors upstream fixtures/run_fixtures.py (Core + team_ops).
  def with_team_ops_runtime(
    auto_assign : Bool = true,
    require_review : Bool = true,
    &
  )
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::TeamOps::TeamOpsSettings.new(
      auto_assign_tasks: auto_assign,
      require_review_for_critical_tasks: require_review,
    )
    rt.load_pack(Chronicle::Packs::TeamOps.pack, JSON.parse(settings.to_json).as_h).should be_true
    Chronicle::Packs::TeamOps.clear_team_ops_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::TeamOps.clear_team_ops_registry
  end
end

include TeamOpsSpecSupport

describe Chronicle::Packs::TeamOps do
  describe "manifest-declared surface" do
    it "matches the upstream team_ops manifest" do
      pack = Chronicle::Packs::TeamOps.pack
      pack.name.should eq("team_ops")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["project", "assignment", "milestone", "workload_estimate", "completion_evidence", "review_request"]
      )
      pack.relation_types.map(&.name).should eq(
        ["assigned_to", "depends_on", "part_of_milestone", "part_of_project", "evidence_for", "review_of", "workload_for"]
      )
      pack.behaviors.map(&.name).should eq(
        ["task_triager", "assignment_suggester", "milestone_tracker", "completion_verifier"]
      )
      pack.tools.map(&.name).should eq(
        ["create_project", "create_milestone", "submit_task_candidate", "assign_task", "mark_task_done"]
      )
      pack.settings_schema.should eq("TeamOpsSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(team_ops_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::TeamOps.pack)
    end
  end

  describe "fixture: task_triage_and_assignment" do
    it "promotes task_candidate observations to Core tasks with assignments" do
      with_team_ops_runtime do |_store, graph, rt|
        project = Chronicle::Packs::TeamOps.create_project_fn(
          graph,
          name: "Q3 Infrastructure",
          description: "Infrastructure improvements for Q3",
          goal: "Reduce p99 latency by 30%",
          owner_ref: "eng-lead@acme.com",
          target_date: "2026-09-30",
        )
        rt.run_until_idle

        milestone = Chronicle::Packs::TeamOps.create_milestone_fn(
          graph,
          project_id: project.id,
          title: "Phase 1: Database optimization",
          description: "Optimize slow queries and add caching layer",
          target_date: "2026-07-15",
        )
        rt.run_until_idle

        graph.objects(type: "project").size.should eq(1)
        graph.objects(type: "milestone").size.should eq(1)

        Chronicle::Packs::TeamOps.submit_task_candidate_fn(
          graph,
          text: "Optimize slow SQL queries in user dashboard assigned to @alice@acme.com",
          owner_ref: "alice@acme.com",
          project_id: project.id,
          milestone_id: milestone.id,
          priority: "high",
        )
        rt.run_until_idle

        Chronicle::Packs::TeamOps.submit_task_candidate_fn(
          graph,
          text: "Add Redis caching layer for session data — assign to @bob@acme.com",
          owner_ref: "bob@acme.com",
          project_id: project.id,
          priority: "medium",
        )
        rt.run_until_idle

        Chronicle::Packs::TeamOps.submit_task_candidate_fn(
          graph,
          text: "Write action item: update runbook with new deployment steps by Friday",
          owner_ref: nil,
          priority: "low",
        )
        rt.run_until_idle

        observations = graph.objects(type: "observation")
        observations.select { |o| JSON.parse(o.data)["category"]?.try(&.as_s?) == "task_candidate" }.size.should eq(3)

        tasks = graph.objects(type: "task")
        tasks.size.should eq(3)
        titles = tasks.map { |t| JSON.parse(t.data)["title"].as_s }
        titles.should contain("Optimize slow SQL queries in user dashboard assigned to @alice@acme.com")
        titles.should contain("Add Redis caching layer for session data — assign to @bob@acme.com")
        titles.should contain("Write action item: update runbook with new deployment steps by Friday")

        assignments = graph.objects(type: "assignment")
        assignments.size.should eq(2)
        principals = assignments.map { |a| JSON.parse(a.data)["principal_ref"].as_s }
        principals.should contain("alice@acme.com")
        principals.should contain("bob@acme.com")

        rel_types = graph.relations.map(&.type).to_set
        rel_types.should contain("assigned_to")
        rel_types.should contain("part_of_project")
        rel_types.should contain("part_of_milestone")
      end
    end

    it "creates a review_request for critical-priority tasks when required" do
      with_team_ops_runtime do |_store, graph, rt|
        graph.add_object("task", {
          "title"     => JSON::Any.new("Fix production outage"),
          "status"    => JSON::Any.new("candidate"),
          "priority"  => JSON::Any.new("critical"),
          "owner_ref" => JSON::Any.new("oncall@acme.com"),
        }.to_json)
        rt.run_until_idle

        review_requests = graph.objects(type: "review_request")
        review_requests.size.should eq(1)
        JSON.parse(review_requests.first.data)["review_type"].as_s.should eq("approval")
        JSON.parse(review_requests.first.data)["reviewer_ref"].as_s.should eq("oncall@acme.com")
      end
    end

    it "skips auto-assignment when auto_assign_tasks is false" do
      with_team_ops_runtime(auto_assign: false) do |_store, graph, rt|
        Chronicle::Packs::TeamOps.submit_task_candidate_fn(
          graph,
          text: "Investigate flaky tests",
          owner_ref: "alice@acme.com",
        )
        rt.run_until_idle

        graph.objects(type: "task").size.should eq(1)
        graph.objects(type: "assignment").size.should eq(0)
      end
    end
  end

  describe "fixture: completion_workflow" do
    it "records completion evidence, marks the task done, and verifies via observation" do
      with_team_ops_runtime(auto_assign: false) do |_store, graph, rt|
        task = graph.add_object("task", {
          "title"       => JSON::Any.new("Deploy new caching service to staging"),
          "description" => JSON::Any.new("Deploy Redis cache to staging environment and run smoke tests"),
          "status"      => JSON::Any.new("active"),
          "priority"    => JSON::Any.new("high"),
          "owner_ref"   => JSON::Any.new("devops@acme.com"),
        }.to_json)
        rt.run_until_idle

        assignment = Chronicle::Packs::TeamOps.assign_task_fn(graph, task.id, "devops@acme.com")
        rt.run_until_idle

        graph.objects(type: "assignment").size.should eq(1)
        graph.relations.select { |r| r.type == "assigned_to" }.size.should eq(1)

        evidence = Chronicle::Packs::TeamOps.mark_task_done_fn(
          graph,
          task_id: task.id,
          evidence_text: "Deployed Redis 7.0 to staging. Smoke tests passed. Cache hit rate: 94%.",
          completed_by_ref: "devops@acme.com",
        )
        rt.run_until_idle

        evidences = graph.objects(type: "completion_evidence")
        evidences.size.should eq(1)
        JSON.parse(evidences.first.data)["completed_by_ref"].as_s.should eq("devops@acme.com")

        updated = graph.get_object(task.id)
        JSON.parse(updated.not_nil!.data)["status"].as_s.should eq("done")

        # completion_verifier: observation with task_id + done keywords.
        graph.add_object("observation", {
          "text"       => JSON::Any.new("Task completed successfully by devops@acme.com — all tests passed"),
          "confidence" => JSON::Any.new(0.9),
          "category"   => JSON::Any.new("decision"),
          "metadata"   => JSON::Any.new({
            "task_id"          => JSON::Any.new(task.id),
            "completed_by_ref" => JSON::Any.new("devops@acme.com"),
          }),
        }.to_json)
        rt.run_until_idle

        graph.objects(type: "completion_evidence").size.should eq(2)
        graph.relations.select { |r| r.type == "evidence_for" }.size.should eq(2)
      end
    end

    it "ignores an observation that mentions done but has no task_id" do
      with_team_ops_runtime do |_store, graph, rt|
        graph.add_object("observation", {
          "text"       => JSON::Any.new("This work is all done and dusted"),
          "confidence" => JSON::Any.new(0.9),
          "category"   => JSON::Any.new("fact"),
        }.to_json)
        rt.run_until_idle

        graph.objects(type: "completion_evidence").size.should eq(0)
      end
    end
  end
end

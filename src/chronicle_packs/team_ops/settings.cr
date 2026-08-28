require "json"

module Chronicle::Packs::TeamOps
  # Settings for the Team/Ops Pack. Ported from upstream packs/team_ops/
  # settings.py (TeamOpsSettings). Controls auto-assignment, task triage
  # hints, workload thresholds, and review-request gating.
  struct TeamOpsSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? auto_assign_tasks : Bool = false
    getter default_capacity_hours_per_week : Float64 = 40.0
    getter task_candidate_hint : String = "task_candidate"
    getter overload_threshold_pct : Float64 = 90.0
    getter milestone_warning_days : Int32 = 7
    getter? require_review_for_critical_tasks : Bool = true

    def initialize(
      @auto_assign_tasks : Bool = false,
      @default_capacity_hours_per_week : Float64 = 40.0,
      @task_candidate_hint : String = "task_candidate",
      @overload_threshold_pct : Float64 = 90.0,
      @milestone_warning_days : Int32 = 7,
      @require_review_for_critical_tasks : Bool = true,
    )
    end
  end
end

require "json"

module Chronicle::Packs::Usage
  # Deterministic defaults for neutral usage projections. Ported from
  # upstream packs/usage/settings.py.
  struct UsageSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = true
    getter default_gate_id : String = "usage.category.default"
    getter default_gate_version : Int32 = 1
    getter min_unique_events : Int32 = 25
    getter min_coverage_days : Int32 = 3
    getter? allow_either : Bool = true

    def initialize(
      @enabled : Bool = true,
      @default_gate_id : String = "usage.category.default",
      @default_gate_version : Int32 = 1,
      @min_unique_events : Int32 = 25,
      @min_coverage_days : Int32 = 3,
      @allow_either : Bool = true,
    )
    end
  end
end

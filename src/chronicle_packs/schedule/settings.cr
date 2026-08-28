require "json"

module Chronicle::Packs::Schedule
  # Settings for the Schedule Pack. Ported from upstream packs/schedule/
  # settings.py (ScheduleSettings). Deliberately small: the pack has no
  # clock of its own, so most timing concerns belong to the host driver.
  struct ScheduleSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter catch_up : String = "skip"

    def initialize(@catch_up : String = "skip")
    end
  end
end

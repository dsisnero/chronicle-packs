require "json"

module Chronicle::Packs::SubjectProfile
  # Settings for the Subject Profile Pack. Ported from upstream
  # packs/subject_profile/settings.py (SubjectProfileSettings).
  struct SubjectProfileSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter owner_subject_ref : String = "owner"
    getter confirmed_trust : Float64 = 0.9

    def initialize(
      @owner_subject_ref : String = "owner",
      @confirmed_trust : Float64 = 0.9,
    )
    end
  end
end

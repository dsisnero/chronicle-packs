require "json"

module Chronicle::Packs::Template
  # Settings for the template pack. Ported from upstream
  # packs/_template/settings.py (TemplateSettings).
  #
  # All fields must have defaults — packs should work with zero
  # configuration.
  struct TemplateSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter? enabled : Bool = true
    getter max_objects_per_run : Int32 = 100

    def initialize(
      @enabled : Bool = true,
      @max_objects_per_run : Int32 = 100,
    )
    end
  end
end

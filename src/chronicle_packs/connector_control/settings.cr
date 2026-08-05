require "json"

module Chronicle::Packs::ConnectorControl
  # Safety bounds for neutral connector control-plane records. Ported from
  # upstream packs/connector_control/settings.py.
  struct ConnectorControlSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter max_refs_per_delta : Int32 = 500
    getter max_exceptions_per_delta : Int32 = 50

    def initialize(@max_refs_per_delta : Int32 = 500, @max_exceptions_per_delta : Int32 = 50)
    end
  end
end

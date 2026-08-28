require "json"

module Chronicle::Packs::Composio
  # Composio route settings. The SDK and key are optional by doctrine. Ported
  # from upstream packs/composio/settings.py (ComposioSettings).
  struct ComposioSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter api_key_env : String = "COMPOSIO_API_KEY"
    getter callback_url : String = "http://127.0.0.1:8000/composio/callback"
    getter max_status_accounts : Int32 = 25

    def initialize(
      @api_key_env : String = "COMPOSIO_API_KEY",
      @callback_url : String = "http://127.0.0.1:8000/composio/callback",
      @max_status_accounts : Int32 = 25,
    )
    end
  end
end

require "json"

module Chronicle::Packs::Bridges
  # Settings for the Diligence-Core bridge. Ported from upstream
  # packs/bridges/__init__.py (DiligenceCoreBridgeSettings).
  #
  # No configuration is required in v0.1 — the upstream Pydantic model is
  # empty; the bridge behaviors take no settings.
  struct DiligenceCoreBridgeSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema
  end
end

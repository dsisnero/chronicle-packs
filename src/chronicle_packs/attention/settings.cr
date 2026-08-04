require "json"

module Chronicle::Packs::Attention
  # Configuration for Attention Pack. Ported from upstream
  # packs/attention/settings.py (AttentionSettings).
  struct AttentionSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter max_observations_per_batch : Int32 = 100
  end
end

require "json"

module Chronicle::Packs::Secrets
  # Configuration for Secrets Pack. Ported from upstream
  # packs/secrets/settings.py (SecretsSettings).
  struct SecretsSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    # Optional prefix prepended to credential names when looking up env vars.
    getter env_prefix : String = ""

    # Whether every credential resolution records a SecretUsageEvent.
    getter? record_usage_events : Bool = true

    # Whether an unresolved credential raises instead of returning nil.
    # Declared for parity; the ported resolution functions keep the
    # return-nil behavior (upstream's field is likewise unconsumed by them).
    getter? fail_on_missing : Bool = false
  end
end

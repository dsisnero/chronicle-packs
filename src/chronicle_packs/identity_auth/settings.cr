require "json"

module Chronicle::Packs::IdentityAuth
  # Configuration for Identity/Auth Pack. Controls how principals are
  # resolved, what role is assigned by default, and how confidently the
  # system recognizes the owner. Ported from upstream
  # packs/identity_auth/settings.py (IdentitySettings).
  struct IdentitySettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    # Identifier strings that unambiguously identify the owner; matched
    # against sender_ref case-insensitively.
    getter owner_identifiers : Array(String) = [] of String

    # Default role for principals that don't match any owner identifier.
    getter default_external_role : String = "unknown"

    # Auth confidence for owner-matched principals.
    getter owner_auth_confidence : Float64 = 0.9

    # Auth confidence for non-owner principals.
    getter default_auth_confidence : Float64 = 0.4

    # Whether auth_context_builder creates an AuthContext per principal.
    getter? create_auth_context : Bool = true

    # Whether permission_checker fires on proposed actions.
    getter? check_permissions_on_proposed_actions : Bool = true

    # Whether principal_resolver deduplicates by normalized sender_ref.
    getter? auto_deduplicate_principals : Bool = true
  end
end

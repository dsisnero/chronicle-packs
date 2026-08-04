require "json"

module Chronicle::Packs::Secrets
  # Secrets object types. Ported from upstream packs/secrets/object_types.py.
  #
  # CRITICAL INVARIANT: actual secret values NEVER appear in graph objects,
  # events, behaviors, artifacts, or logs. CredentialRef contains a NAME
  # only; the value is resolved at execution time from the environment or a
  # managed source.

  # Defines a permission scope for credentials.
  @[Chronicle::Packs::Annotations::ObjectType(name: "secret_scope")]
  struct SecretScope
    include JSON::Serializable

    getter scope_name : String
    getter description : String = ""
    getter allowed_providers : Array(String) = [] of String
    getter allowed_operations : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A reference to a credential — stores the NAME only, never the secret.
  @[Chronicle::Packs::Annotations::ObjectType(name: "credential_ref")]
  struct CredentialRef
    include JSON::Serializable

    getter name : String
    getter scope : String = ""
    getter provider_hint : String? = nil
    getter last_used_at : String? = nil
    getter use_count : Int32 = 0
    getter? enabled : Bool = true
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Records that a credential was registered or resolved (name only).
  @[Chronicle::Packs::Annotations::ObjectType(name: "secret_usage_event")]
  struct SecretUsageEvent
    include JSON::Serializable

    getter credential_ref_name : String
    getter behavior_name : String? = nil
    getter? resolved : Bool = false
    getter frame_id : String? = nil
    getter timestamp : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Records that a credential was rotated (replaced with a new secret).
  @[Chronicle::Packs::Annotations::ObjectType(name: "credential_rotation_event")]
  struct CredentialRotationEvent
    include JSON::Serializable

    getter credential_ref_name : String
    getter rotated_by : String? = nil
    getter reason : String = ""
    getter timestamp : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

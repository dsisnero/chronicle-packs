require "json"

module Chronicle::Packs::IdentityAuth
  # Identity/Auth object types. Ported from upstream
  # packs/identity_auth/object_types.py.
  #
  # Design rules:
  #   - Principal never stores passwords, tokens, or raw secrets
  #   - auth_confidence is the system's confidence in the identity claim,
  #     not the strength of the authentication mechanism
  #   - Roles and permissions are additive — higher roles accumulate
  #     capabilities

  # The default role→capability hierarchy (additive). `owner` is the
  # wildcard. Nested module so the DSL's `pack` macro (which assumes every
  # direct constant is a type) doesn't trip over the map constant.
  module RoleCapabilities
    MAP = {
      "owner"        => Set{"*"},
      "admin"        => Set{"manage_settings", "manage_collaborators", "read", "write", "execute", "comment"},
      "collaborator" => Set{"read", "write", "comment"},
      "external"     => Set{"read_public"},
      "customer"     => Set{"read_own"},
      "unknown"      => Set(String).new,
      "blocked"      => Set(String).new,
    }
  end

  # Whether the role's implied capability set allows the action. The
  # shared decision behind Principal#can?, permission_checker, and the
  # check_principal_permission tool.
  def self.can_action?(role : String, action : String) : Bool
    caps = RoleCapabilities::MAP[role]? || Set(String).new
    caps.includes?("*") || caps.includes?(action)
  end

  # A recognized identity with an assigned role and confidence score.
  @[Chronicle::Packs::Annotations::ObjectType(name: "principal")]
  struct Principal
    include JSON::Serializable

    getter name : String
    getter role : String = "unknown"
    getter auth_confidence : Float64 = 0.5
    getter identifiers : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter channel : String? = nil
    getter entity_id : String? = nil
    getter last_seen_at : String? = nil
    getter seen_count : Int32 = 1
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    # Upstream names are is_owner()/is_external(); Crystal predicate naming.
    def owner? : Bool
      role == "owner"
    end

    def external? : Bool
      role.in?({"external", "customer", "unknown"})
    end

    def can?(action : String) : Bool
      IdentityAuth.can_action?(role, action)
    end
  end

  # Session-scoped authentication state for a principal.
  @[Chronicle::Packs::Annotations::ObjectType(name: "auth_context")]
  struct AuthContext
    include JSON::Serializable

    getter principal_id : String
    getter principal_role : String
    getter channel : String = "unknown"
    getter session_id : String? = nil
    getter verified_at : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Named role with an explicit capability list. Roles are additive.
  @[Chronicle::Packs::Annotations::ObjectType(name: "role")]
  struct Role
    include JSON::Serializable

    getter name : String
    getter capabilities : Array(String) = [] of String
    getter description : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Explicit action/resource grant scoped to a role (additive only).
  @[Chronicle::Packs::Annotations::ObjectType(name: "permission")]
  struct Permission
    include JSON::Serializable

    getter action : String
    getter resource : String = "*"
    getter granted_to_role : String
    getter granted_by_principal_id : String? = nil
    getter expires_at : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Temporary scope transfer from one principal to another.
  @[Chronicle::Packs::Annotations::ObjectType(name: "delegation")]
  struct Delegation
    include JSON::Serializable

    getter from_principal_id : String
    getter to_principal_id : String
    getter scope : String
    getter expires_at : String? = nil
    getter rationale : String = ""
    getter? revoked : Bool = false
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

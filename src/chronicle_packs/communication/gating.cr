require "json"

module Chronicle::Packs::Communication
  # Reply gating — identity on the respond path. Ported from upstream
  # packs/communication/gating.py. One function, one policy decision, shared
  # by every channel adapter: may this sender receive a full conversational
  # reply? Adapters call `decide_reply` at INGESTION time and stamp the
  # verdict onto the comm_message they create, so responders can match it
  # declaratively.
  #
  # Fail-closed by design: a restrictive policy with no resolvable principal
  # deflects.

  # Roles allowed per policy. "blocked" is denied even under "open".
  # Nested so the DSL pack macro doesn't treat these as typed constants.
  module GateConstants
    ALLOWED_ROLES = {
      "known"      => Set{"owner", "admin", "collaborator"},
      "owner_only" => Set{"owner", "admin"},
    }
    REPLY_POLICIES = %w(open known owner_only)
  end

  # Decide whether *sender_ref* gets a full reply under *reply_policy*.
  # Returns a Hash with :gate ("open"|"deflect"), :role, and :reason.
  def self.decide_reply(graph : Chronicle::GraphProjection, sender_ref : String?, reply_policy : String) : Hash(String, JSON::Any)
    unless GateConstants::REPLY_POLICIES.includes?(reply_policy)
      return {
        "gate"   => JSON::Any.new("deflect"),
        "role"   => JSON::Any.new(nil),
        "reason" => JSON::Any.new("unknown reply_policy #{reply_policy.inspect} (use one of #{GateConstants::REPLY_POLICIES.inspect})"),
      }
    end

    principal = begin
      Chronicle::Packs::IdentityAuth.resolve_known_principal(graph, sender_ref || "")
    rescue
      nil
    end
    role = principal.try { |principal_data| principal_data["role"]?.try(&.as_s?) }

    if role == "blocked"
      return {"gate" => JSON::Any.new("deflect"), "role" => JSON::Any.new(role), "reason" => JSON::Any.new("principal is blocked")}
    end

    if reply_policy == "open"
      return {"gate" => JSON::Any.new("open"), "role" => JSON::Any.new(role), "reason" => JSON::Any.new("policy is open")}
    end

    allowed = GateConstants::ALLOWED_ROLES[reply_policy]
    if role && allowed.includes?(role)
      return {"gate" => JSON::Any.new("open"), "role" => JSON::Any.new(role), "reason" => JSON::Any.new("role #{role.inspect} allowed by #{reply_policy.inspect}")}
    end

    if principal.nil?
      return {
        "gate"   => JSON::Any.new("deflect"),
        "role"   => JSON::Any.new(nil),
        "reason" => JSON::Any.new("policy #{reply_policy.inspect} and sender is unrecognized (no principal — seed the owner via register_principal)"),
      }
    end
    {"gate" => JSON::Any.new("deflect"), "role" => JSON::Any.new(role), "reason" => JSON::Any.new("role #{role.inspect} not allowed by policy #{reply_policy.inspect}")}
  end
end

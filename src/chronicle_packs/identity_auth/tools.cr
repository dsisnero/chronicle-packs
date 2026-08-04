require "json"
require "time"

module Chronicle::Packs::IdentityAuth
  # Identity/Auth tools. Ported from upstream packs/identity_auth/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared `Chronicle::Tool`s wrap them; chronicle's Tool
  # model is args-only (no graph injection), so the wrappers read a graph
  # bound by the host via `bound_graph`.

  # The graph the declared tools operate on. chronicle's Tool model does
  # not inject a graph at call time; hosts bind one here when the pack is
  # wired into a runtime (see plans/parity.md divergences).
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # The deterministic permission-check result contract.
  struct PermissionCheck
    include JSON::Serializable

    getter? allowed : Bool
    getter role : String
    getter reason : String

    def initialize(@allowed : Bool, @role : String, @reason : String)
    end
  end

  # The register_principal result contract.
  struct PrincipalRegistration
    include JSON::Serializable

    getter principal_id : String
    getter role : String
    getter? created : Bool

    def initialize(@principal_id : String, @role : String, @created : Bool)
    end
  end

  # Find the most recent principal matching a sender_ref.
  def self.lookup_principal_fn(graph : Chronicle::GraphProjection, sender_ref : String) : Hash(String, JSON::Any)?
    graph.objects(type: "principal").each do |obj|
      data = JSON.parse(obj.data)
      ref = data["identifiers"]?.try(&.["ref"]?.try(&.as_s?))
      if ref == sender_ref
        return {"id" => JSON::Any.new(obj.id)}.merge(data.as_h)
      end
    end
    nil
  end

  # Deterministic permission decision for a principal on an action.
  def self.check_principal_permission_fn(
    graph : Chronicle::GraphProjection,
    principal_id : String,
    action : String,
    risk_class : String = "medium",
  ) : PermissionCheck
    obj = graph.get_object(principal_id)
    if obj.nil?
      return PermissionCheck.new(false, "unknown", "principal_not_found")
    end

    role = JSON.parse(obj.data)["role"]?.try(&.as_s?) || "unknown"

    if role == "blocked"
      return PermissionCheck.new(false, role, "principal_blocked")
    end

    if risk_class.in?({"high", "critical"}) && !role.in?({"owner", "admin"})
      return PermissionCheck.new(false, role, "risk_class_#{risk_class}_requires_owner_or_admin")
    end

    if can_action?(role, action)
      return PermissionCheck.new(true, role, "role_allows")
    end

    PermissionCheck.new(false, role, "insufficient_role")
  end

  # Create or promote a Principal with an explicit role. Idempotent by
  # normalized sender_ref; keeps the dedup registry in sync.
  def self.register_principal_fn(
    graph : Chronicle::GraphProjection,
    sender_ref : String,
    role : String,
    name : String? = nil,
    channel : String = "unknown",
  ) : PrincipalRegistration
    now = Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
    norm = _normalize_identifier(sender_ref)

    if existing_id = principal_registry[norm]?
      begin
        if existing = graph.get_object(existing_id)
          graph.patch_object(existing_id, _merge_patch(existing.data, {
            "role"         => JSON::Any.new(role),
            "last_seen_at" => JSON::Any.new(now),
          }))
        end
      rescue
      end
      return PrincipalRegistration.new(existing_id, role, false)
    end

    identifiers = {"ref" => JSON::Any.new(sender_ref)}
    identifiers["email"] = JSON::Any.new(sender_ref) if sender_ref.includes?('@')

    data = JSON.build do |json|
      json.object do
        json.field "name", name || sender_ref
        json.field "role", role
        json.field "auth_confidence", 1.0
        json.field "identifiers", identifiers
        json.field "channel", channel
        json.field "last_seen_at", now
        json.field "seen_count", 1
        json.field "metadata", {"registered_by" => JSON::Any.new("register_principal")}
      end
    end
    principal = graph.add_object("principal", data)
    principal_registry[norm] = principal.id

    PrincipalRegistration.new(principal.id, role, true)
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------
  #
  # Annotated with @[Tool] so the DSL collects them into the pack's tool
  # list (single `args` parameter, matching chronicle's Tool contract).

  @[Chronicle::Packs::Annotations::Tool(name: "lookup_principal", description: "Find an existing principal by sender_ref (email, Slack ID, phone, etc.). Returns the principal data dict or null if not found.", deterministic: true)]
  def lookup_principal_tool(args : String) : String
    input = JSON.parse(args).as_h
    sender_ref = input["sender_ref"]?.try(&.as_s?) || ""
    lookup_principal_fn(bound_graph_or_raise, sender_ref).try(&.to_json) || "null"
  end

  @[Chronicle::Packs::Annotations::Tool(name: "check_principal_permission", description: "Check whether a principal has permission for an action. Returns {allowed, role, reason}.", deterministic: true)]
  def check_principal_permission_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = check_principal_permission_fn(
      bound_graph_or_raise,
      input["principal_id"]?.try(&.as_s?) || "",
      input["action"]?.try(&.as_s?) || "",
      input["risk_class"]?.try(&.as_s?) || "medium",
    )
    result.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "register_principal", description: "Create or promote a Principal with an explicit role (e.g. seed the owner). Idempotent by normalized sender_ref. Returns {principal_id, role, created}.", deterministic: true)]
  def register_principal_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = register_principal_fn(
      bound_graph_or_raise,
      input["sender_ref"]?.try(&.as_s?) || "",
      input["role"]?.try(&.as_s?) || "",
      input["name"]?.try(&.as_s?),
      input["channel"]?.try(&.as_s?) || "unknown",
    )
    result.to_json
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "identity_auth tools require a bound graph (set IdentityAuth.bound_graph)"
    )
  end
end

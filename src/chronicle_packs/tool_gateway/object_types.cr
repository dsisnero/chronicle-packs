require "json"

module Chronicle::Packs::ToolGateway
  # Tool Gateway Pack object and relation types. Ported from upstream
  # packs/tool_gateway/object_types.py. All external capability calls must
  # flow through this pack. credential_ref stores a NAME only; input_data is
  # recorded as-is; CapabilityResult.output_data is sanitized and size-limited.

  # One transport route serving a canonical service/account profile.
  struct IntegrationRoute
    include JSON::Serializable

    getter path : String
    getter route_ref : String
    getter status : String = "active"
    getter connected_account_id : String?
    getter schema_version : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Conservatively classified canonical (service, operation) capability.
  struct IntegrationCapability
    include JSON::Serializable

    getter operation : String
    getter action_class : String
    getter classification_source : String = "default"
    getter route : String
    getter provider_operation : String?
    getter input_schema_fingerprint : String?
    getter idempotency : String = "none"
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A profile surface's predicted downstream yield, never a truth claim.
  struct IntegrationSignal
    include JSON::Serializable

    getter surface : String
    getter candidate_types : Array(String) = [] of String
    getter estimated_richness : String = "unknown"
    getter confidence : Float64 = 0.0
    getter provenance : Array(String) = [] of String
  end

  # One inspectable profile claim with epistemic state of its own.
  struct IntegrationClaim
    include JSON::Serializable

    getter claim_key : String
    getter value : JSON::Any
    getter confidence : Float64
    getter freshness : String = "unknown"
    getter provenance : Array(String) = [] of String
    getter classification_source : String = "evidence"
    getter asserted_by : String
    getter observed_at_event_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Thin profile for a route provider; it never inventories the catalog.
  @[Chronicle::Packs::Annotations::ObjectType(name: "aggregator_profile", description: "A thin route-provider profile: auth state and available/enabled services only.")]
  struct AggregatorProfile
    include JSON::Serializable

    getter profile_identity : String
    getter aggregator : String
    getter user_ref : String
    getter auth_state : String
    getter available_services : Array(String) = [] of String
    getter enabled_services : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Versioned understanding of one canonical (service, account).
  @[Chronicle::Packs::Annotations::ObjectType(name: "integration_profile", description: "Versioned, evidence-backed understanding of one canonical service/account.")]
  struct IntegrationProfile
    include JSON::Serializable

    getter profile_identity : String
    getter profile_version : Int32 = 1
    getter service : String
    getter account_ref : String
    getter account_display : String?
    getter status : String = "active"
    getter routes : Array(IntegrationRoute) = [] of IntegrationRoute
    getter scopes_granted : Array(String) = [] of String
    getter scopes_available : Array(String) = [] of String
    getter facets : Array(String) = [] of String
    getter capability_inventory : Array(IntegrationCapability) = [] of IntegrationCapability
    getter data_topology : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter signal_map : Array(IntegrationSignal) = [] of IntegrationSignal
    getter claims : Array(IntegrationClaim) = [] of IntegrationClaim
    getter health : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter exploration_receipts : Array(String) = [] of String
    getter supersedes_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Budgeted R0 probe receipt used to build or refresh a profile.
  @[Chronicle::Packs::Annotations::ObjectType(name: "integration_exploration", description: "A budgeted R0 exploration receipt with a shape fingerprint.")]
  struct IntegrationExploration
    include JSON::Serializable

    getter receipt_identity : String
    getter service : String
    getter account_ref : String
    getter route : String
    getter profile_id : String?
    getter probe_call_ids : Array(String) = [] of String
    getter budget : Int32
    getter? structural_only : Bool = true
    getter shape_fingerprint : String?
    getter status : CallStatus = CallStatus::Proposed
    getter injection_flags : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Closed string-literal sets for the capability surface.

  enum RiskClass
    Low
    Medium
    High
    Critical
  end

  enum CallStatus
    Proposed
    PolicyChecking
    Approved
    Rejected
    Executing
    Done
    Failed
  end

  enum ProviderKind
    Local
    Api
    Mcp
    Sdk
    Webhook
  end

  enum ToolPolicyStatus
    Candidate
    Promoted
    Demoted
    Disabled
  end

  # A standing-scope tool policy — automation as a promoted prediction.
  @[Chronicle::Packs::Annotations::ObjectType(name: "tool_policy", description: "A standing-scope tool policy: a versioned, provenance-carrying governed artifact (ADR 0018).")]
  struct ToolPolicy
    include JSON::Serializable

    getter policy_id : String
    getter policy_version : Int32 = 1
    getter scope_key : String
    getter capability_key : String
    getter action_class : String
    getter status : ToolPolicyStatus = ToolPolicyStatus::Candidate
    getter rule_id : String = ""
    getter rule_version : Int32 = 0
    getter evidence : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter proposed_by : String = ""
    getter approved_by : String = ""
    getter promotion_history : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter demotion_reason : String = ""
    getter missed_prediction_refs : Array(String) = [] of String
    getter? is_fixture : Bool = false
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A registered external capability provider.
  @[Chronicle::Packs::Annotations::ObjectType(name: "capability_provider", description: "A registered external capability provider (API, local function, MCP, SDK).")]
  struct CapabilityProvider
    include JSON::Serializable

    getter name : String
    getter kind : ProviderKind
    getter base_url : String?
    getter description : String = ""
    getter capabilities : Array(String) = [] of String
    getter credential_ref_name : String?
    getter? enabled : Bool = true
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A proposed or executing capability call.
  @[Chronicle::Packs::Annotations::ObjectType(name: "capability_call", description: "A proposed or executing capability call. All external calls must flow through here.")]
  struct CapabilityCall
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter provider_id : String
    getter provider_name : String = ""
    getter capability_name : String
    getter input_data : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter credential_ref_name : String?
    getter credential_ref_id : String?
    getter risk_class : RiskClass = RiskClass::Medium
    getter action_class : String = ""
    getter status : CallStatus = CallStatus::Proposed
    getter proposed_by : String?
    getter frame_id : String?
    getter proposed_at : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      provider_id : String, capability_name : String,
      provider_name : String = "", input_data : Hash(String, JSON::Any) = {} of String => JSON::Any,
      credential_ref_name : String? = nil, credential_ref_id : String? = nil,
      risk_class : RiskClass = RiskClass::Medium, action_class : String = "", status : CallStatus = CallStatus::Proposed,
      proposed_by : String? = nil, frame_id : String? = nil, proposed_at : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @provider_id = provider_id
      @capability_name = capability_name
      @provider_name = provider_name
      @input_data = input_data
      @credential_ref_name = credential_ref_name
      @credential_ref_id = credential_ref_id
      @risk_class = risk_class
      @action_class = action_class
      @status = status
      @proposed_by = proposed_by
      @frame_id = frame_id
      @proposed_at = proposed_at
      @metadata = metadata
    end

    define_copy_with(provider_id, capability_name, provider_name, input_data, credential_ref_name, credential_ref_id, risk_class, action_class, status, proposed_by, frame_id, proposed_at, metadata)
  end

  # Records that a capability call was approved for execution.
  @[Chronicle::Packs::Annotations::ObjectType(name: "capability_approval", description: "Records that a capability_call was approved. Serves as the graph-visible trigger for call_executor.")]
  struct CapabilityApproval
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter call_id : String
    getter provider_id : String = ""
    getter provider_name : String = ""
    getter capability_name : String = ""
    getter action_class : String = ""
    getter input_data : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter credential_ref_name : String?
    getter credential_ref_id : String?
    getter frame_id : String?
    getter policy_decision : String = "auto_approved"
    getter approver : String = "policy_enforcer"
    getter approved_at : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      call_id : String, provider_id : String = "", provider_name : String = "",
      capability_name : String = "", action_class : String = "",
      input_data : Hash(String, JSON::Any) = {} of String => JSON::Any,
      credential_ref_name : String? = nil, credential_ref_id : String? = nil,
      frame_id : String? = nil, policy_decision : String = "auto_approved",
      approver : String = "policy_enforcer", approved_at : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @call_id = call_id
      @provider_id = provider_id
      @provider_name = provider_name
      @capability_name = capability_name
      @action_class = action_class
      @input_data = input_data
      @credential_ref_name = credential_ref_name
      @credential_ref_id = credential_ref_id
      @frame_id = frame_id
      @policy_decision = policy_decision
      @approver = approver
      @approved_at = approved_at
      @metadata = metadata
    end

    define_copy_with(call_id, provider_id, provider_name, capability_name, action_class, input_data, credential_ref_name, credential_ref_id, frame_id, policy_decision, approver, approved_at, metadata)
  end

  # Records that a held capability call was explicitly denied.
  @[Chronicle::Packs::Annotations::ObjectType(name: "capability_denial", description: "Records that a held capability_call was explicitly denied, by whom, and why.")]
  struct CapabilityDenial
    include JSON::Serializable

    getter call_id : String
    getter provider_name : String = ""
    getter capability_name : String = ""
    getter action_class : String = ""
    getter denier : String = ""
    getter reason : String = ""
    getter denied_at : String?
    getter frame_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      call_id : String, denier : String, reason : String = "",
      provider_name : String = "", capability_name : String = "",
      action_class : String = "", denied_at : String? = nil, frame_id : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @call_id = call_id
      @provider_name = provider_name
      @capability_name = capability_name
      @action_class = action_class
      @denier = denier
      @reason = reason
      @denied_at = denied_at
      @frame_id = frame_id
      @metadata = metadata
    end
  end

  # The result of an executed capability call.
  @[Chronicle::Packs::Annotations::ObjectType(name: "capability_result", description: "The result of an executed capability call. Mapped to a Core source object.")]
  struct CapabilityResult
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter call_id : String
    getter provider_name : String = ""
    getter capability_name : String = ""
    getter output_data : String = ""
    getter error : String?
    getter? success : Bool = true
    getter executed_at : String?
    getter? sanitized : Bool = false
    getter? untrusted : Bool = true
    getter injection_flags : Array(String) = [] of String
    getter source_id : String?
    getter frame_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      call_id : String, provider_name : String = "", capability_name : String = "",
      output_data : String = "", error : String? = nil, success : Bool = true,
      executed_at : String? = nil, sanitized : Bool = false, untrusted : Bool = true,
      injection_flags : Array(String) = [] of String, source_id : String? = nil,
      frame_id : String? = nil, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @call_id = call_id
      @provider_name = provider_name
      @capability_name = capability_name
      @output_data = output_data
      @error = error
      @success = success
      @executed_at = executed_at
      @sanitized = sanitized
      @untrusted = untrusted
      @injection_flags = injection_flags
      @source_id = source_id
      @frame_id = frame_id
      @metadata = metadata
    end

    define_copy_with(call_id, provider_name, capability_name, output_data, error, success, executed_at, sanitized, untrusted, injection_flags, source_id, frame_id, metadata)
  end

  # A capability result matched known prompt-injection patterns.
  @[Chronicle::Packs::Annotations::ObjectType(name: "injection_flag", description: "Audit record that a capability result matched prompt-injection patterns. Never blocks execution.")]
  struct InjectionFlag
    include JSON::Serializable

    getter call_id : String
    getter result_id : String = ""
    getter provider_name : String = ""
    getter capability_name : String = ""
    getter patterns : Array(String) = [] of String
    getter excerpt : String = ""
    getter flagged_at : String = ""
    getter frame_id : String?
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      call_id : String, result_id : String = "", provider_name : String = "",
      capability_name : String = "", patterns : Array(String) = [] of String,
      excerpt : String = "", flagged_at : String = "", frame_id : String? = nil,
      metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      @call_id = call_id
      @result_id = result_id
      @provider_name = provider_name
      @capability_name = capability_name
      @patterns = patterns
      @excerpt = excerpt
      @flagged_at = flagged_at
      @frame_id = frame_id
      @metadata = metadata
    end
  end
end

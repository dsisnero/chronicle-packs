require "json"
require "set"

module Chronicle::Packs::Gmail
  # Canonical Gmail capabilities served through the Composio route. Ported
  # from upstream packs/gmail/capabilities.py.
  #
  # Capability identity is always ``gmail.<operation>``. Composio tool slugs,
  # account ids, and toolkit versions are route metadata. Provider responses
  # are stored as replay artifacts; graph capability results contain only
  # hashes, shape fingerprints, and safe status fields — not mailbox bodies.

  alias RouteExecute = Proc(String, Hash(String, JSON::Any), String, String, String, JSON::Any)
  alias RouteResolve = Proc(Array(String), String, Hash(String, JSON::Any))

  # Parameters for gmail.profile.get / gmail.labels.list.
  record AccountInput,
    user_id : String,
    connected_account_id : String

  record GmailProfileInput,
    user_id : String,
    connected_account_id : String

  record GmailLabelsInput,
    user_id : String,
    connected_account_id : String

  record GmailFetchInput,
    user_id : String,
    connected_account_id : String,
    query : String = "",
    page_token : String = "",
    max_results : Int32 = 25,
    include_payload : Bool = true

  record GmailMessageInput,
    user_id : String,
    connected_account_id : String,
    message_id : String

  record GmailHistoryInput,
    user_id : String,
    connected_account_id : String,
    start_history_id : String,
    page_token : String = "",
    max_results : Int32 = 100

  record GmailCreateDraftInput,
    user_id : String,
    connected_account_id : String,
    recipient_email : String,
    idempotency_key : String,
    subject : String = "",
    body : String = "",
    cc : Array(String) = [] of String,
    bcc : Array(String) = [] of String,
    thread_id : String = "",
    is_html : Bool = false

  record GmailSendDraftInput,
    user_id : String,
    connected_account_id : String,
    draft_id : String,
    idempotency_key : String

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module CapabilityConstants
    INTERNAL_FIELDS = Set{"user_id", "connected_account_id", "idempotency_key"}

    COMPOSIO_OPERATIONS = {
      "profile.get"    => "GMAIL_GET_PROFILE",
      "labels.list"    => "GMAIL_LIST_LABELS",
      "messages.fetch" => "GMAIL_FETCH_EMAILS",
      "messages.get"   => "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
      "history.list"   => "GMAIL_LIST_HISTORY",
      "drafts.create"  => "GMAIL_CREATE_EMAIL_DRAFT",
      "drafts.send"    => "GMAIL_SEND_DRAFT",
    }
  end

  # Route code is resolved only when the default adapter actually executes;
  # loading the canonical Gmail pack does not require Composio.
  def self._default_composio_execute(
    provider_operation : String,
    arguments : Hash(String, JSON::Any),
    user_id : String,
    connected_account_id : String,
    schema_version : String,
  ) : JSON::Any
    result = Composio.composio_transport.execute(
      tool_slug: provider_operation,
      arguments: arguments,
      user_id: user_id,
      connected_account_id: connected_account_id,
      version: schema_version,
    )
    JSON::Any.new(result)
  end

  # Resolve canonical candidates into one concrete provider tool version via
  # the composio transport seam. (In the Crystal port the transport always
  # implements resolve_tool — the abstract ComposioTransport guarantees it.)
  def self._default_composio_resolve(candidates : Array(String), schema_version : String) : Hash(String, JSON::Any)
    Composio.composio_transport.resolve_tool(
      toolkit: "gmail",
      candidates: candidates,
      requested_version: schema_version,
    )
  end

  # Normalize a provider value to plain JSON-compatible data. In the Crystal
  # port values already arrive as JSON::Any; kept for surface parity.
  def self._plain(value : JSON::Any) : JSON::Any
    value
  end

  # Execute one route operation, store the raw provider result as a replay
  # artifact, and return only hashes/fingerprints/status to the graph.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _execute_to_artifact error/version branches
  def self._execute_to_artifact(
    *,
    provider_candidates : Array(String),
    payload : Hash(String, JSON::Any),
    artifact_store_dir : String,
    route : String,
    schema_version : String,
    execute_route : RouteExecute,
    resolve_route : RouteResolve?,
  ) : Hash(String, JSON::Any)
    user_id = payload["user_id"]?.try(&.as_s?) || ""
    account_id = payload["connected_account_id"]?.try(&.as_s?) || ""
    remote = {} of String => JSON::Any
    payload.each do |key, value|
      next if CapabilityConstants::INTERNAL_FIELDS.includes?(key)
      next if Gmail._empty_value?(value)
      remote[key] = value
    end

    resolved =
      if resolve_route
        resolve_route.call(provider_candidates, schema_version)
      else
        {
          "tool_slug"                => JSON::Any.new(provider_candidates.first? || ""),
          "version"                  => JSON::Any.new(schema_version),
          "input_schema_fingerprint" => JSON::Any.new(nil),
          "resolution"               => JSON::Any.new("configured"),
        } of String => JSON::Any
      end
    provider_operation = resolved["tool_slug"]?.try(&.as_s?) || ""
    resolved_version = resolved["version"]?.try(&.as_s?) || ""
    raise Exception.new("route #{route.inspect} returned an incomplete tool resolution") if provider_operation.empty? || resolved_version.empty?

    result = execute_route.call(provider_operation, remote, user_id, account_id, resolved_version)
    encoded = ToolGateway._canonical(result)
    _artifact_ref, digest = ActivityNormalizer::Replay.store_replay_artifact(encoded, artifact_store_dir)
    successful = true
    error = nil.as(String?)
    if result.raw.is_a?(Hash)
      hash = result.raw.as(Hash(String, JSON::Any))
      successful = hash["successful"]?.try(&.as_bool?) || hash["success"]?.try(&.as_bool?) || true
      if err = hash["error"]?
        error = err.as_s?.try { |value| value[0, 500] }
      end
    end

    {
      "ok"                       => JSON::Any.new(successful && error.nil?),
      "successful"               => JSON::Any.new(successful),
      "error"                    => error ? JSON::Any.new(error) : JSON::Any.new(nil),
      "route"                    => JSON::Any.new(route),
      "provider_operation"       => JSON::Any.new(provider_operation),
      "route_schema_version"     => JSON::Any.new(resolved_version),
      "route_resolution"         => JSON::Any.new(resolved["resolution"]?.try(&.as_s?) || "configured"),
      "input_schema_fingerprint" => resolved["input_schema_fingerprint"]? || JSON::Any.new(nil),
      "connected_account_id"     => JSON::Any.new(account_id),
      "replay_mode"              => JSON::Any.new("artifact"),
      "replay_artifact_locator"  => JSON::Any.new(ActivityNormalizer::Replay.portable_artifact_locator(digest)),
      "shape_fingerprint"        => JSON::Any.new(ToolGateway.shape_fingerprint(result)),
    }
  end

  # Register the seven canonical Gmail capabilities on the gateway.
  def self.register_gmail_capabilities(
    *,
    artifact_store_dir : String = ".activegraph/replay-artifacts",
    toolkit_version : String = "latest",
    route : String = "composio",
    execute_route : RouteExecute? = nil,
    operation_map : Hash(String, String)? = nil,
    resolve_route : RouteResolve? = nil,
  ) : Tuple(ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec, ToolGateway::CapabilitySpec)
    executor = execute_route || ->(provider_operation : String, arguments : Hash(String, JSON::Any), user_id : String, connected_account_id : String, schema_version : String) : JSON::Any {
      _default_composio_execute(provider_operation, arguments, user_id, connected_account_id, schema_version)
    }
    operations = operation_map || CapabilityConstants::COMPOSIO_OPERATIONS
    resolver =
      if resolve_route
        resolve_route
      elsif execute_route.nil? && route == "composio"
        ->(candidates : Array(String), schema_version : String) : Hash(String, JSON::Any) {
          _default_composio_resolve(candidates, schema_version)
        }
      else
        nil
      end

    handler = ->(operation : String) : Proc(Hash(String, JSON::Any), Hash(String, JSON::Any)) {
      configured = operations[operation]?
      raise ArgumentError.new("route #{route.inspect} does not map Gmail operation #{operation.inspect}") if configured.nil?
      provider_candidates = configured.split('|').map(&.strip).reject(&.empty?)
      if provider_candidates.empty?
        raise ArgumentError.new("route #{route.inspect} maps Gmail operation #{operation.inspect} to no candidates")
      end
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        _execute_to_artifact(
          provider_candidates: provider_candidates,
          payload: input_data,
          artifact_store_dir: artifact_store_dir,
          route: route,
          schema_version: toolkit_version,
          execute_route: executor,
          resolve_route: resolver,
        )
      }
    }

    spec_profile = ToolGateway.register_local_capability(
      "gmail", "profile.get", handler.call("profile.get"),
      description: "Read Gmail account identity, totals, and history watermark.",
      risk_class: "low", action_class: "R0",
    )
    spec_labels = ToolGateway.register_local_capability(
      "gmail", "labels.list", handler.call("labels.list"),
      description: "List Gmail label topology without reading message content.",
      risk_class: "low", action_class: "R0",
    )
    spec_fetch = ToolGateway.register_local_capability(
      "gmail", "messages.fetch", handler.call("messages.fetch"),
      description: "Fetch one bounded Gmail message page for ingestion.",
      risk_class: "low", action_class: "R0",
    )
    spec_get = ToolGateway.register_local_capability(
      "gmail", "messages.get", handler.call("messages.get"),
      description: "Fetch one Gmail message by provider-stable id.",
      risk_class: "low", action_class: "R0",
    )
    spec_history = ToolGateway.register_local_capability(
      "gmail", "history.list", handler.call("history.list"),
      description: "Read Gmail mailbox changes from a provider history watermark.",
      risk_class: "low", action_class: "R0",
    )
    spec_create = ToolGateway.register_local_capability(
      "gmail", "drafts.create", handler.call("drafts.create"),
      description: "Create a reversible Gmail-hosted draft from a local candidate.",
      risk_class: "medium", action_class: "R2",
    )
    spec_send = ToolGateway.register_local_capability(
      "gmail", "drafts.send", handler.call("drafts.send"),
      description: "Send an existing Gmail draft; outward R3 forever.",
      risk_class: "high", action_class: "R3",
    )
    {spec_profile, spec_labels, spec_fetch, spec_get, spec_history, spec_create, spec_send}
  end
end

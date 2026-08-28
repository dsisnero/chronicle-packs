require "json"
require "digest"
require "uri"

module Chronicle::Packs::Composio
  # Optional Composio SDK adapter behind a small, injectable route seam.
  # Ported from upstream packs/composio/client.py.
  #
  # Managed OAuth uses the current Connect Link/session authorization flow.
  # The legacy ``connected_accounts.initiate`` path is deliberately absent:
  # Composio retired it for managed OAuth on 2026-07-03.

  # Raised when Composio is unavailable (no key, no SDK, catalog miss, ...).
  class ComposioUnavailable < Exception
  end

  # The injectable route seam. A host wires a real transport via
  # configure_composio_transport; the SDK-backed default raises
  # ComposioUnavailable (no Crystal Composio SDK).
  abstract class ComposioTransport
    abstract def authorize(*, user_id : String, toolkit : String, callback_url : String) : Hash(String, JSON::Any)
    abstract def list_connections(*, user_id : String, toolkit : String, limit : Int32) : Array(Hash(String, JSON::Any))
    abstract def execute(*, tool_slug : String, arguments : Hash(String, JSON::Any), user_id : String, connected_account_id : String, version : String) : Hash(String, JSON::Any)
    abstract def resolve_tool(*, toolkit : String, candidates : Array(String), requested_version : String) : Hash(String, JSON::Any)
  end

  # Normalize an SDK/pydantic value to plain JSON-compatible data. In the
  # Crystal port values already arrive as JSON::Any; kept for surface parity.
  def self._plain(value : JSON::Any) : JSON::Any
    value
  end

  # Harden canonical candidates into one concrete provider tool version.
  # Discovery is deliberately bounded to caller-supplied candidates: the
  # Composio catalog is route metadata, not a capability namespace we mirror
  # into the graph. A concrete version and schema fingerprint are returned so
  # the execution receipt says exactly what was selected.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream resolve_catalog_tool candidate/version/deprecation branches
  def self.resolve_catalog_tool(
    rows : Array(Hash(String, JSON::Any)),
    *,
    toolkit : String,
    candidates : Array(String),
    requested_version : String = "latest",
  ) : Hash(String, JSON::Any)
    ordered = [] of String
    candidates.each do |row|
      slug = row.strip
      ordered << slug if !slug.empty? && !ordered.includes?(slug)
    end
    raise ComposioUnavailable.new("no provider tool candidates configured for #{toolkit}") if ordered.empty?

    by_slug = {} of String => Hash(String, JSON::Any)
    rows.each do |row|
      slug = row["slug"]?.try(&.as_s?) || row["name"]?.try(&.as_s?) || ""
      row_toolkit = row["toolkit"]? || row["app"]? || JSON::Any.new("")
      toolkit_slug =
        if row_toolkit.as_h?
          row_toolkit.as_h["slug"]?.try(&.as_s?) || row_toolkit.as_h["name"]?.try(&.as_s?)
        else
          row_toolkit.as_s?
        end
      if !slug.empty? && (toolkit_slug.nil? || toolkit_slug.downcase == toolkit.downcase)
        by_slug[slug] = row
      end
    end

    selected = nil
    ordered.each do |slug|
      if row = by_slug[slug]?
        selected = row
        break
      end
    end
    if selected.nil?
      raise ComposioUnavailable.new(
        "Composio #{toolkit} catalog contains none of the configured tools: #{ordered.join(", ")}"
      )
    end

    slug = selected["slug"]?.try(&.as_s?) || selected["name"]?.try(&.as_s?) || ""
    current = (selected["version"]?.try(&.as_s?) || "").strip
    available = [] of String
    (selected["available_versions"]?.try(&.as_a) || [] of JSON::Any).each do |row|
      v = row.as_s?
      available << v if v && !v.empty?
    end
    if !current.empty? && !available.includes?(current)
      available.insert(0, current)
    end
    requested = (requested_version || "latest").strip
    resolved_version =
      if requested.in?({"", "latest"})
        if current.empty?
          raise ComposioUnavailable.new("Composio returned no concrete version for #{slug}")
        end
        current
      elsif available.includes?(requested)
        requested
      else
        choices = available.empty? ? "none" : available.join(", ")
        raise ComposioUnavailable.new(
          "configured Composio version #{requested.inspect} is unavailable for #{slug}; available versions: #{choices}"
        )
      end

    deprecated =
      selected["is_deprecated"]?.try(&.as_bool?) == true ||
        (selected["deprecated"]?.try(&.as_h) || {} of String => JSON::Any)["is_deprecated"]?.try(&.as_bool?) == true
    raise ComposioUnavailable.new("configured Composio tool #{slug} is deprecated") if deprecated

    {
      "tool_slug"                => JSON::Any.new(slug),
      "version"                  => JSON::Any.new(resolved_version),
      "input_schema_fingerprint" => JSON::Any.new(ToolGateway.shape_fingerprint(selected["input_parameters"]? || JSON::Any.new({} of String => JSON::Any))),
      "resolution"               => JSON::Any.new("catalog"),
    }
  end

  # The SDK-backed default transport. The Crystal port has no Composio SDK,
  # so its methods fail closed with a clear message; hosts wire a real
  # transport via configure_composio_transport.
  class SDKComposioTransport < ComposioTransport
    getter api_key : String
    getter resolved_tools = {} of {String, Array(String), String} => Hash(String, JSON::Any)

    def initialize(*, @api_key : String, @resolved_tools : Hash({String, Array(String), String}, Hash(String, JSON::Any)) = {} of {String, Array(String), String} => Hash(String, JSON::Any))
    end

    def authorize(*, user_id : String, toolkit : String, callback_url : String) : Hash(String, JSON::Any)
      raise ComposioUnavailable.new("Composio SDK is not available in the Crystal port; install activegraph-packs[composio] or wire a host ComposioTransport via configure_composio_transport")
    end

    def list_connections(*, user_id : String, toolkit : String, limit : Int32) : Array(Hash(String, JSON::Any))
      raise ComposioUnavailable.new("Composio SDK is not available in the Crystal port; install activegraph-packs[composio] or wire a host ComposioTransport via configure_composio_transport")
    end

    def execute(*, tool_slug : String, arguments : Hash(String, JSON::Any), user_id : String, connected_account_id : String, version : String) : Hash(String, JSON::Any)
      raise ComposioUnavailable.new("Composio SDK is not available in the Crystal port; install activegraph-packs[composio] or wire a host ComposioTransport via configure_composio_transport")
    end

    def resolve_tool(*, toolkit : String, candidates : Array(String), requested_version : String) : Hash(String, JSON::Any)
      raise ComposioUnavailable.new("Composio SDK is not available in the Crystal port; install activegraph-packs[composio] or wire a host ComposioTransport via configure_composio_transport")
    end
  end

  # The configured transport (nil until configure_composio_transport).
  class_property transport : ComposioTransport? = nil
  # request_id → redirect_url (bearer-like Connect Links, kept out of the graph).
  class_property redirects = {} of String => String

  def self.configure_composio_transport(transport : ComposioTransport?) : Nil
    self.transport = transport
    self.redirects = {} of String => String
  end

  # Return the configured transport, or build the SDK default. Raises
  # ComposioUnavailable when the default has no API key.
  def self.composio_transport(*, api_key_env : String = "COMPOSIO_API_KEY") : ComposioTransport
    if configured = transport
      return configured
    end
    key = ENV[api_key_env]?
    key = key.try(&.strip)
    if key.nil? || key.empty?
      raise ComposioUnavailable.new("#{api_key_env} is not set; add a Composio project key and restart the engine")
    end
    SDKComposioTransport.new(api_key: key)
  end

  # Keep bearer-like Connect Links out of graph output and event history.
  def self.store_redirect(request_id : String, redirect_url : String) : Hash(String, JSON::Any)
    if request_id.empty? || redirect_url.empty?
      raise Exception.new("Composio returned no connection request id or redirect URL")
    end
    parsed = URI.parse(redirect_url)
    if parsed.scheme != "https" || parsed.host.nil?
      raise Exception.new("Composio returned an invalid Connect Link")
    end
    redirects[request_id] = redirect_url
    {
      "connection_request_id"    => JSON::Any.new(request_id),
      "redirect_origin"          => JSON::Any.new("#{parsed.scheme}://#{parsed.host}"),
      "redirect_url_fingerprint" => JSON::Any.new(ToolGateway.safe_sha256_fingerprint(redirect_url)),
    }
  end

  def self.take_redirect(request_id : String) : String?
    redirects.delete(request_id)
  end

  # Return only non-secret account identity/status fields.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream connection_summary toolkit-shape branches
  def self.connection_summary(row : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    toolkit = row["toolkit"]? || row["app"]? || JSON::Any.new("")
    toolkit_slug =
      if toolkit.as_h?
        toolkit.as_h["slug"]?.try(&.as_s?) || toolkit.as_h["name"]?.try(&.as_s?)
      else
        toolkit.as_s?
      end
    toolkit_slug = toolkit_slug.nil? || toolkit_slug.empty? ? nil : toolkit_slug
    {
      "id"         => JSON::Any.new(row["id"]?.try(&.as_s?) || row["connected_account_id"]?.try(&.as_s?) || ""),
      "status"     => JSON::Any.new((row["status"]?.try(&.as_s?) || "UNKNOWN").upcase),
      "toolkit"    => JSON::Any.new(toolkit_slug || row["toolkit_slug"]?.try(&.as_s?) || ""),
      "created_at" => row["created_at"]? || JSON::Any.new(nil),
      "updated_at" => row["updated_at"]? || JSON::Any.new(nil),
    }
  end
end

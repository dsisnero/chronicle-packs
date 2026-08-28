require "json"

module Chronicle::Packs::PublicPresence
  # The R0 public-presence fetch capability (zero-key floor). Ported from
  # upstream packs/importers/public_presence/capabilities.py.
  #
  # Registered through the Tool Gateway so every fetch is a recorded,
  # policy-checked capability call. An HTTP GET observes the outside world
  # and changes nothing in it: action class R0. The keyed upgrade seam: a
  # Firecrawl-grade provider registers its own capability and
  # PublicPresenceSettings.fetch_provider / fetch_capability select it.
  #
  # In the Crystal port the actual network edge is a host seam: the
  # registered handler runs the ToolGateway `web.fetch_url` fetcher when
  # configured, and fails closed otherwise (the deterministic specs use a
  # stub handler).

  # The fetch handler receives input_data with url/timeout_seconds/max_chars.
  # Returns a dict with url/final_url/status/title/text/truncated.
  def self._fetch_page(input : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    url = input["url"]?.try(&.as_s?) || ""
    timeout_seconds = input["timeout_seconds"]?.try(&.as_f?) || 10.0
    max_chars = input["max_chars"]?.try(&.as_i?) || 200_000
    fetcher = ToolGateway.web_fetch_fetcher
    if fetcher.nil?
      raise PackError.new("public_presence.fetch_page requires a host web_fetch seam (ToolGateway.configure_web_fetch); the gateway fails closed on live external I/O without an explicit fetcher")
    end
    text, status, final_url = fetcher.call(url, timeout_seconds)
    text, title = html_to_text(text || "")
    truncated = text.size > max_chars
    {
      "url"       => JSON::Any.new(url),
      "final_url" => JSON::Any.new(final_url || url),
      "status"    => JSON::Any.new(status),
      "title"     => JSON::Any.new(title),
      "text"      => JSON::Any.new(text[0, max_chars]),
      "truncated" => JSON::Any.new(truncated),
    }
  end

  # Register `public_presence.fetch_page`. Hosts call this at startup.
  def self.register_public_presence_capability : CapabilitySpec
    ToolGateway.register_local_capability(
      "public_presence", "fetch_page",
      ->(input : Hash(String, JSON::Any)) { _fetch_page(input) },
      description: "Fetch one public web page (profile, personal site) and reduce it to plain text. Read-only, zero-key, stdlib parsing.",
      risk_class: "low",
      action_class: "R0",
    )
  end
end

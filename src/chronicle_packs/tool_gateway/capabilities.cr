require "json"

module Chronicle::Packs::ToolGateway
  # Reference capability registrations for the Tool Gateway. Ported from
  # upstream packs/tool_gateway/capabilities.py: the runtime ships reference
  # capabilities with the metadata (schema, risk class, description) that
  # makes them policy-checkable and LLM-exposable. Hosts call these once at
  # startup; nothing here touches a graph.

  # Host seam for the actual HTTP GET. An unset seam fails closed — the
  # gateway never performs ctx-less external I/O on its own (mirrors the
  # v1.9 runtime's external_io_mode guard).
  class_property web_fetch_fetcher : Proc(String, Float64, {String, Int32, String})?

  # Register ``web.fetch_url`` — read-only page fetch. Risk class defaults
  # to 'low' (read-only, no side effects), making it auto-approvable under
  # the default gateway policy — the canonical first tool for agentic chat.
  # Action class R0: an HTTP GET observes the outside world and changes
  # nothing in it.
  def self.register_web_fetch_capability(risk_class : String = "low") : CapabilitySpec
    register_local_capability(
      "web", "fetch_url",
      ->(input : Hash(String, JSON::Any)) {
        url = input["url"]?.try(&.as_s?) || ""
        timeout_seconds = input["timeout_seconds"]?.try(&.as_f?) || 10.0
        if fetcher = web_fetch_fetcher
          text, status, final_url = fetcher.call(url, timeout_seconds)
          # Size limiting happens at the gateway (max_output_chars) — return
          # the full result and let policy own truncation.
          {"text" => JSON::Any.new(text), "status" => JSON::Any.new(status), "final_url" => JSON::Any.new(final_url)}
        else
          raise Chronicle::Packs::PackError.new("web_fetch host seam is unset; the gateway fails closed on live external I/O without an explicit fetcher")
        end
      },
      description: "Fetch the text of a public web page by URL (HTTP GET, follows redirects, read-only).",
      risk_class: risk_class,
      action_class: "R0",
    )
  end
end

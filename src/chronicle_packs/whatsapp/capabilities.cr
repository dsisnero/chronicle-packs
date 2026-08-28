require "json"
require "http/client"

module Chronicle::Packs::WhatsApp
  # WhatsApp Adapter Pack gateway capabilities. Ported from upstream
  # packs/whatsapp/capabilities.py.
  #
  # Registers ``whatsapp.send_message`` — the ONLY place this adapter touches
  # the network, and it runs inside the Tool Gateway's execution path: the
  # access token arrives via a host-provided seam (injected at execution
  # time, never stored in the graph), and every send is a first-class
  # capability_call in the audit trail.
  #
  # Divergence: the ported ToolGateway handler signature receives only
  # input_data (no execution_context), so the token is pulled from an
  # injectable `token_provider` seam instead of the gateway's execution
  # context; unset (or with no configured phone_number_id), `_send_message`
  # fails closed with the same reasons as upstream.

  # JSON POST returning (status, parsed JSON) — injectable for offline tests.
  alias HttpPost = Proc(String, JSON::Any, {Int32, Hash(String, JSON::Any)})

  # Default JSON POST, used when no seam is injected.
  def self._default_http_post(url : String, body : JSON::Any) : {Int32, Hash(String, JSON::Any)}
    headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}
    response = HTTP::Client.post(url, headers: headers, body: body.to_json)
    payload = response.body.empty? ? {} of String => JSON::Any : JSON.parse(response.body).as_h
    {response.status_code, payload}
  end

  # Parameters for whatsapp.send_message.
  record SendMessageInput,
    to : String,
    text : String

  # The send implementation. Posts to {api_base}/{phone_number_id}/messages
  # with a Bearer token; fails closed without a token or a configured
  # phone_number_id.
  def self._send_message(
    input_data : Hash(String, JSON::Any),
    api_base : String,
    phone_number_id : String,
    http_post : HttpPost,
    token_provider : Proc(String)? = nil,
  ) : Hash(String, JSON::Any)
    token = token_provider.try(&.call)
    if token.nil? || token.empty?
      return {
        "ok"     => JSON::Any.new(false),
        "reason" => JSON::Any.new("no access token injected — register the WHATSAPP_ACCESS_TOKEN credential"),
      }
    end
    if phone_number_id.empty?
      return {
        "ok"     => JSON::Any.new(false),
        "reason" => JSON::Any.new("phone_number_id not configured — pass it to register_send_capability (or set WHATSAPP_PHONE_NUMBER_ID for the demo server)"),
      }
    end

    to = input_data["to"]?.try(&.as_s?) || ""
    text = input_data["text"]?.try(&.as_s?) || ""
    url = "#{api_base}/#{phone_number_id}/messages"
    body_data = JSON::Any.new({
      "messaging_product" => JSON::Any.new("whatsapp"),
      "recipient_type"    => JSON::Any.new("individual"),
      "to"                => JSON::Any.new(to),
      "type"              => JSON::Any.new("text"),
      "text"              => JSON::Any.new({"body" => JSON::Any.new(text)}),
    })
    begin
      _status, body = http_post.call(url, body_data)
      messages = body["messages"]?.try(&.as_a) || [] of JSON::Any
      sent = !messages.empty?
      message_id = messages.first? ? messages.first.as_h["id"]? : nil
      {"ok" => JSON::Any.new(sent), "message_id" => message_id || JSON::Any.new(nil)}
    rescue ex
      {"ok" => JSON::Any.new(false), "reason" => JSON::Any.new("#{ex.class}: #{ex.message}")}
    end
  end

  # Register whatsapp.send_message on the gateway. Requires the Tool Gateway
  # Pack (returns nil without it).
  def self.register_send_capability(
    *,
    phone_number_id : String? = nil,
    api_base : String = "https://graph.facebook.com/v20.0",
    http_post : HttpPost = ->(url : String, body : JSON::Any) : {Int32, Hash(String, JSON::Any)} { _default_http_post(url, body) },
    token_provider : Proc(String)? = nil,
  ) : ToolGateway::CapabilitySpec?
    ToolGateway.register_local_capability(
      "whatsapp", "send_message",
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        _send_message(input_data, api_base, phone_number_id || "", http_post, token_provider: token_provider)
      },
      description: "Send a text message via the WhatsApp Cloud API.",
      risk_class: "low",
      # R3: a delivered message cannot be unsent — an outward,
      # irreversible action regardless of the legacy risk label.
      action_class: "R3",
      credential_ref_name: "WHATSAPP_ACCESS_TOKEN",
    )
  end
end

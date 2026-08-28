require "json"
require "http/client"

module Chronicle::Packs::Telegram
  # Telegram Adapter Pack gateway capabilities. Ported from upstream
  # packs/telegram/capabilities.py.
  #
  # Registers ``telegram.send_message`` — the ONLY place this adapter touches
  # the network, and it runs inside the Tool Gateway's execution path: the bot
  # token arrives via a host-provided seam (injected at execution time, never
  # stored in the graph), the output is sanitized before recording, and every
  # send is a first-class capability_call in the audit trail.
  #
  # Divergence: the ported ToolGateway handler signature receives only
  # input_data (no execution_context), so the token is pulled from an
  # injectable `token_provider` seam instead of the gateway's execution
  # context; unset, `_send_message` fails closed with the same "no bot token
  # injected" reason as upstream.

  # JSON POST returning (status, parsed JSON) — injectable for offline tests.
  alias HttpPost = Proc(String, Hash(String, String), {Int32, Hash(String, JSON::Any)})

  # Default form-encoded POST (JSON body), used when no seam is injected.
  def self._default_http_post(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)}
    headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}
    response = HTTP::Client.post(url, headers: headers, body: data.to_json)
    payload = response.body.empty? ? {} of String => JSON::Any : JSON.parse(response.body).as_h
    {response.status_code, payload}
  end

  # Parameters for telegram.send_message.
  record SendMessageInput,
    chat_id : String,
    text : String

  # The send implementation. Token comes from `token_provider` (host seam);
  # without one, the call fails closed. Posts to
  # {api_base}/bot{token}/sendMessage and returns ok + message_id.
  def self._send_message(
    input_data : Hash(String, JSON::Any),
    api_base : String,
    http_post : HttpPost,
    token_provider : Proc(String)? = nil,
  ) : Hash(String, JSON::Any)
    token = token_provider.try(&.call)
    if token.nil? || token.empty?
      return {
        "ok"     => JSON::Any.new(false),
        "reason" => JSON::Any.new("no bot token injected — register the TELEGRAM_BOT_TOKEN credential"),
      }
    end

    chat_id = input_data["chat_id"]?.try(&.as_s?) || ""
    text = input_data["text"]?.try(&.as_s?) || ""
    url = "#{api_base}/bot#{token}/sendMessage"
    begin
      _status, body = http_post.call(url, {"chat_id" => chat_id, "text" => text})
      ok = body["ok"]?.try(&.as_bool?) || false
      message_id = body["result"]?.try(&.as_h).try(&.["message_id"]?)
      {"ok" => JSON::Any.new(ok), "message_id" => message_id || JSON::Any.new(nil)}
    rescue ex
      {"ok" => JSON::Any.new(false), "reason" => JSON::Any.new("#{ex.class}: #{ex.message}")}
    end
  end

  # Register telegram.send_message on the gateway. Requires the Tool Gateway
  # Pack (returns nil without it).
  def self.register_send_capability(
    *,
    api_base : String = "https://api.telegram.org",
    http_post : HttpPost = ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} { _default_http_post(url, data) },
    token_provider : Proc(String)? = nil,
  ) : ToolGateway::CapabilitySpec?
    ToolGateway.register_local_capability(
      "telegram", "send_message",
      ->(input_data : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        _send_message(input_data, api_base, http_post, token_provider: token_provider)
      },
      description: "Send a text message to a Telegram chat via the Bot API.",
      risk_class: "low",
      # R3: a delivered message cannot be unsent — an outward,
      # irreversible action regardless of the legacy risk label.
      action_class: "R3",
      credential_ref_name: "TELEGRAM_BOT_TOKEN",
    )
  end
end

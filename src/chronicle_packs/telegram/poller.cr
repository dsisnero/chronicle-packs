require "json"
require "http/client"
require "uri"

module Chronicle::Packs::Telegram
  # Telegram long-polling driver — edge code, not pack code.
  #
  # Runs OUTSIDE the reactive graph: polls the Bot API's getUpdates and hands
  # each update to a running assistant, either over HTTP (the demo server's
  # POST /channels/telegram/update) or in-process via a callback. The pack
  # itself never polls, sleeps, or reads tokens — that is this driver's job,
  # exactly as the schedule pack's tick driver owns the clock.
  #
  # The token is read from the environment here ONLY to authenticate the
  # getUpdates long-poll; it is never sent to the assistant (inbound updates
  # are user content). Outbound sends resolve their own credential through
  # the Secrets Pack inside the gateway. All network calls are injectable so
  # the driver is testable offline.

  alias PollerHttpGet = Proc(String, {Int32, Hash(String, JSON::Any)})
  alias WebhookPost = Proc(String, JSON::Any, Nil)

  def self._default_http_get(url : String) : {Int32, Hash(String, JSON::Any)}
    response = HTTP::Client.get(url)
    payload = response.body.empty? ? {} of String => JSON::Any : JSON.parse(response.body).as_h
    {response.status_code, payload}
  end

  def self._default_http_post(url : String, body : JSON::Any) : Nil
    HTTP::Client.post(url, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body.to_json)
  end

  # Poll getUpdates; returns the result list (empty on non-ok responses).
  def self._get_updates(
    api_base : String,
    token : String,
    offset : Int32,
    timeout : Int32,
    http_get : PollerHttpGet = ->(url : String) : {Int32, Hash(String, JSON::Any)} { _default_http_get(url) },
  ) : Array(Hash(String, JSON::Any))
    qs = URI::Params.encode({"offset" => offset.to_s, "timeout" => timeout.to_s})
    url = "#{api_base}/bot#{token}/getUpdates?#{qs}"
    _status, body = http_get.call(url)
    if body["ok"]?.try(&.as_bool?) || false
      body["result"]?.try(&.as_a) ? body["result"].as_a.map(&.as_h) : [] of Hash(String, JSON::Any)
    else
      [] of Hash(String, JSON::Any)
    end
  end

  # Forward one update to the assistant server's webhook endpoint.
  def self._post_to_server(server : String, update : Hash(String, JSON::Any), http_post : WebhookPost) : Nil
    http_post.call("#{server.rstrip('/')}/channels/telegram/update", JSON::Any.new(update))
  end

  # The long-poll loop. Reads TELEGRAM_BOT_TOKEN from the environment (raises
  # if unset), advances the offset past each handled update, and retries on
  # transient failures. `should_stop` lets a host end the loop (tests).
  def self.run_poller(
    server : String,
    *,
    api_base : String = "https://api.telegram.org",
    poll_timeout : Int32 = 50,
    http_get : PollerHttpGet = ->(url : String) : {Int32, Hash(String, JSON::Any)} { _default_http_get(url) },
    http_post : WebhookPost = ->(url : String, body : JSON::Any) : Nil { _default_http_post(url, body) },
    should_stop : Proc(Bool)? = nil,
  ) : Nil
    token = ENV["TELEGRAM_BOT_TOKEN"]?
    raise Chronicle::Packs::PackError.new("TELEGRAM_BOT_TOKEN is not set") if token.nil? || token.empty?

    offset = 0
    loop do
      break if should_stop.try(&.call) == true
      begin
        updates = _get_updates(api_base, token, offset, poll_timeout, http_get)
        updates.each do |update|
          offset = Math.max(offset, (update["update_id"]?.try(&.as_i?) || 0) + 1)
          _post_to_server(server, update, http_post)
        end
      rescue ex
        STDERR.puts "[telegram-poller] #{ex.class}: #{ex}; retrying in 5s"
        sleep 5.seconds
      end
    end
  end
end

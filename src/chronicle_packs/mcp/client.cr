require "json"
require "http/client"

module Chronicle::Packs::MCP
  # Outbound MCP client — transport-injectable. Ported from upstream
  # packs/mcp/client.py. Speaks the Model Context Protocol (JSON-RPC 2.0)
  # as a client so the assistant can consume any MCP server's tools:
  #
  #   * StdioTransport — spawns the server as a subprocess and exchanges
  #     newline-delimited JSON-RPC over stdin/stdout (the MCP stdio framing).
  #   * HttpTransport  — POSTs JSON-RPC to a streamable-HTTP endpoint,
  #     accepting both plain-JSON and SSE-framed responses, echoing the
  #     `Mcp-Session-Id` header once the server assigns one.
  #
  # MCPClient is the protocol layer on top (handshake, list_tools,
  # call_tool); it is deterministic given a transport. Nothing here touches
  # a graph or makes policy decisions — governance lives in registry.cr.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module MCPConstants
    MCPConstants::PROTOCOL_VERSION = "2025-06-18"
    MCPConstants::CLIENT_INFO = {"name" => "activegraph-packs", "version" => "0.2"}
    SERVER_INFO  = {"name" => "activegraph-assistant", "version" => "0.2"}

    # JSON-RPC error codes
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    UNAUTHORIZED     = -32001
    FORBIDDEN        = -32003
  end

  # A JSON-RPC level error returned by the MCP server.
  class MCPError < Exception
  end

  # Anything that can exchange one JSON-RPC message with an MCP server.
  abstract class MCPTransport
    abstract def request(payload : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    abstract def notify(payload : Hash(String, JSON::Any)) : Nil
    abstract def close : Nil
  end

  # MCP stdio framing: one JSON-RPC message per line over a subprocess.
  # The network/process edge is the host's responsibility; this transport
  # is best-effort (not exercised by the deterministic specs, matching
  # upstream, where only fake/http transports are tested).
  class StdioTransport < MCPTransport
    getter timeout : Float64
    @proc : Process?
    @input : IO?
    @output : IO?

    def initialize(command : Array(String), *, env : Hash(String, String)? = nil, @timeout : Float64 = 30.0)
      in_read, in_write = IO.pipe
      out_read, out_write = IO.pipe
      @proc = Process.new(command, input: in_read, output: out_write, error: Process::Redirect::Close, env: env)
      in_read.close
      out_write.close
      @input = in_write
      @output = out_read
    end

    def _send(payload : Hash(String, JSON::Any)) : Nil
      input = @input
      raise MCPError.new("stdio transport: process stdin closed") if input.nil?
      input.print(payload.to_json)
      input.print('\n')
      input.flush
    end

    def request(payload : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      _send(payload)
      want_id = payload["id"]?
      output = @output
      raise MCPError.new("stdio transport: server closed the stream") if output.nil?
      loop do
        line = output.gets
        raise MCPError.new("stdio transport: server closed the stream") if line.nil?
        line = line.strip
        next if line.empty?
        message = JSON.parse(line).as_h? || next
        return message if message["id"]? == want_id
      end
    end

    def notify(payload : Hash(String, JSON::Any)) : Nil
      _send(payload)
    end

    def close : Nil
      @proc.try(&.terminate)
    rescue
    end
  end

  # MCP streamable HTTP: JSON-RPC over POST, JSON or SSE responses.
  # The POST is injectable (defaults to a real HTTP::Client POST) so the
  # deterministic specs never touch the network.
  class HttpTransport < MCPTransport
    alias HttpPostFn = Proc(String, Hash(String, JSON::Any), Hash(String, String), Float64, {String, Hash(String, String)})

    # Default JSON POST returning (response body, response headers).
    def self._default_http_post(url : String, payload : Hash(String, JSON::Any), headers : Hash(String, String), timeout : Float64) : {String, Hash(String, String)}
      http_headers = HTTP::Headers.new
      headers.each { |key, value| http_headers[key] = value }
      response = HTTP::Client.post(url, headers: http_headers, body: payload.to_json)
      response_headers = {} of String => String
      response.headers.each { |key, values| response_headers[key] = values.join(",") }
      {response.body, response_headers}
    end

    class_property http_post : HttpPostFn = ->(url : String, payload : Hash(String, JSON::Any), headers : Hash(String, String), timeout : Float64) : {String, Hash(String, String)} {
      HttpTransport._default_http_post(url, payload, headers, timeout)
    }

    getter url : String
    getter timeout : Float64
    @headers : Hash(String, String)
    @session_id : String? = nil

    def initialize(@url : String, *, headers : Hash(String, String)? = nil, @timeout : Float64 = 30.0)
      @headers = headers || {} of String => String
    end

    def _post(payload : Hash(String, JSON::Any)) : {JSON::Any?, Hash(String, String)}
      headers = {"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}.merge(@headers)
      if session_id = @session_id
        headers["Mcp-Session-Id"] = session_id
      end
      body, response_headers = self.class.http_post.call(@url, payload, headers, @timeout)
      if session = self.class._session_from_headers(response_headers)
        @session_id = session
      end
      if body.strip.empty?
        return {nil, response_headers}
      end
      content_type = (response_headers.find { |key, _value| key.downcase == "content-type" } || {"", ""})[1].downcase
      if content_type.includes?("text/event-stream")
        return {self.class._first_jsonrpc_from_sse(body, payload["id"]?), response_headers}
      end
      message = JSON.parse(body).as_h? || {} of String => JSON::Any
      {JSON::Any.new(message), response_headers}
    end

    def self._session_from_headers(headers : Hash(String, String)) : String?
      headers.each do |key, value|
        return value if key.downcase == "mcp-session-id"
      end
      nil
    end

    def self._first_jsonrpc_from_sse(body : String, want_id : JSON::Any?) : JSON::Any?
      body.split("\n\n").each do |chunk|
        data_lines = [] of String
        chunk.split('\n').each do |line|
          data_lines << line["data:".size..].strip if line.starts_with?("data:")
        end
        next if data_lines.empty?
        message = JSON.parse(data_lines.join("\n")).as_h?
        next if message.nil?
        return JSON::Any.new(message) if message["id"]? == want_id
      end
      nil
    end

    def request(payload : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      message, _headers = _post(payload)
      if message.nil?
        raise MCPError.new("no JSON-RPC response for id=#{payload["id"]?.inspect}")
      end
      message.as_h
    end

    def notify(payload : Hash(String, JSON::Any)) : Nil
      _post(payload)
      nil
    end

    def close : Nil
    end
  end

  # Protocol-level MCP client over an injected transport.
  class MCPClient
    getter server_info : Hash(String, JSON::Any) = {} of String => JSON::Any
    @transport : MCPTransport
    @ids = 0
    @initialized = false

    def initialize(@transport : MCPTransport)
    end

    def _rpc(method : String, params : Hash(String, JSON::Any)? = nil) : JSON::Any?
      @ids += 1
      payload = {"jsonrpc" => JSON::Any.new("2.0"), "id" => JSON::Any.new(@ids), "method" => JSON::Any.new(method)}
      payload["params"] = JSON::Any.new(params) if params
      message = @transport.request(payload)
      if err = message["error"]?
        err_h = err.as_h? || {} of String => JSON::Any
        raise MCPError.new("#{method}: #{err_h["message"]?.try(&.as_s?) || ""} (code #{err_h["code"]?})")
      end
      message["result"]?
    end

    # Run the MCP handshake; idempotent. (Crystal reserves `initialize` for
    # the constructor, so the protocol handshake is `handshake`.)
    def handshake : Hash(String, JSON::Any)
      return server_info if @initialized
      rpc_result = _rpc("initialize", {
        "protocolVersion" => JSON::Any.new(MCPConstants::PROTOCOL_VERSION),
        "capabilities"    => JSON::Any.new({} of String => JSON::Any),
        "clientInfo"      => JSON::Any.new(MCPConstants::CLIENT_INFO.transform_values { |value| JSON::Any.new(value) }),
      })
      result = rpc_result.try(&.as_h?) || {} of String => JSON::Any
      @server_info = result["serverInfo"]?.try(&.as_h?) || {} of String => JSON::Any
      @transport.notify({"jsonrpc" => JSON::Any.new("2.0"), "method" => JSON::Any.new("notifications/initialized")})
      @initialized = true
      @server_info
    end

    # Return the server's tool definitions (name/description/inputSchema).
    def list_tools : Array(Hash(String, JSON::Any))
      handshake
      rpc_result = _rpc("tools/list")
      result = rpc_result.try(&.as_h?) || {} of String => JSON::Any
      (result["tools"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_h?)
    end

    # Invoke one tool; returns the raw MCP result (content blocks).
    def call_tool(name : String, arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      handshake
      rpc_result = _rpc("tools/call", {"name" => JSON::Any.new(name), "arguments" => JSON::Any.new(arguments)})
      rpc_result.try(&.as_h?) || {} of String => JSON::Any
    end

    # Invoke one tool and flatten its content blocks to text.
    # Returns {text, is_error}.
    def call_tool_text(name : String, arguments : Hash(String, JSON::Any)) : {String, Bool}
      result = call_tool(name, arguments)
      parts = [] of String
      (result["content"]?.try(&.as_a?) || [] of JSON::Any).each do |block|
        block_h = block.as_h? || {} of String => JSON::Any
        if block_h["type"]?.try(&.as_s?) == "text"
          parts << (block_h["text"]?.try(&.as_s?) || "")
        else
          parts << "[non-text content: #{block_h["type"]?.try(&.as_s?) || "unknown"}]"
        end
      end
      {parts.join("\n"), result["isError"]?.try(&.as_bool?) || false}
    end

    def close : Nil
      @transport.close
    end
  end

  # Build a client from a transport description (the settings shape).
  def self.make_client(
    transport_kind : String,
    *,
    url : String = "",
    command : Array(String)? = nil,
    headers : Hash(String, String)? = nil,
    timeout : Float64 = 30.0,
  ) : MCPClient
    case transport_kind
    when "http"
      raise ArgumentError.new("http transport requires a url") if url.empty?
      MCPClient.new(HttpTransport.new(url, headers: headers, timeout: timeout))
    when "stdio"
      if command.nil?
        raise ArgumentError.new("stdio transport requires a command")
      end
      MCPClient.new(StdioTransport.new(command, timeout: timeout))
    else
      raise ArgumentError.new("unknown MCP transport #{transport_kind.inspect} (use 'http' or 'stdio')")
    end
  end
end

require "json"
require "db"
require "sqlite3"
require "http/client"
require "uri"

module Chronicle::Packs::Secrets
  module Managed
    # Managed credentials behind the resolve_credential_fn seam. Resolution
    # consults the environment first (always wins), then any registered
    # CredentialSource. The first managed source is OAuth 2.0 Device
    # Authorization Grant (RFC 8628). Tokens live in the SQLite store and
    # ONLY there — never in the graph, events, or logs.

    # Anything that can resolve a credential name to a secret value.
    abstract class CredentialSource
      abstract def resolve(credential_name : String) : String?
      abstract def label : String
    end

    class_property sources : Array(CredentialSource) = [] of CredentialSource

    def self.register_credential_source(source : CredentialSource) : Nil
      sources << source
    end

    def self.registered_credential_sources : Array(CredentialSource)
      sources
    end

    def self.clear_credential_sources : Nil
      self.sources = [] of CredentialSource
    end

    # ------------------------------------------------------------------ token store

    # SQLite-backed token persistence, keyed by credential name. A separate
    # file from the event log because its contents are secrets.
    class OAuthTokenStore
      @db : DB::Database

      def initialize(db_path : String = ":memory:")
        # sqlite3::memory: is the in-memory form; file paths get the scheme.
        @db = DB.open(db_path == ":memory:" ? "sqlite3::memory:" : "sqlite3::#{db_path}")
        @db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS oauth_tokens (
            credential_name TEXT PRIMARY KEY,
            access_token TEXT NOT NULL,
            refresh_token TEXT,
            token_type TEXT DEFAULT 'Bearer',
            scope TEXT DEFAULT '',
            expires_at REAL,
            obtained_at REAL,
            provider TEXT DEFAULT ''
          )
          SQL
      end

      def put(
        credential_name : String,
        *,
        access_token : String,
        refresh_token : String? = nil,
        expires_in : Float64? = nil,
        token_type : String = "Bearer",
        scope : String = "",
        provider : String = "",
        now : Float64? = nil,
      ) : Nil
        now = now || Time.utc.to_unix_f
        expires_at = expires_in ? now + expires_in : nil
        @db.exec(
          "INSERT OR REPLACE INTO oauth_tokens
           (credential_name, access_token, refresh_token, token_type, scope, expires_at, obtained_at, provider)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          credential_name, access_token, refresh_token, token_type, scope, expires_at, now, provider
        )
      end

      def get(credential_name : String) : Hash(String, JSON::Any)?
        @db.query_one?(
          "SELECT access_token, refresh_token, token_type, scope, expires_at, obtained_at, provider
           FROM oauth_tokens WHERE credential_name = ?",
          credential_name
        ) do |result_set|
          {
            "access_token"  => JSON::Any.new(result_set.read(String)),
            "refresh_token" => JSON::Any.new(result_set.read(String?)),
            "token_type"    => JSON::Any.new(result_set.read(String)),
            "scope"         => JSON::Any.new(result_set.read(String)),
            "expires_at"    => JSON::Any.new(result_set.read(Float64?)),
            "obtained_at"   => JSON::Any.new(result_set.read(Float64?)),
            "provider"      => JSON::Any.new(result_set.read(String)),
          }
        end
      end

      def delete(credential_name : String) : Nil
        @db.exec("DELETE FROM oauth_tokens WHERE credential_name = ?", credential_name)
      end

      # Stored credential NAMES (safe to display; values stay put).
      def names : Array(String)
        @db.query_all("SELECT credential_name FROM oauth_tokens ORDER BY credential_name") do |result_set|
          result_set.read(String)
        end
      end

      def close : Nil
        @db.close
      end
    end

    # ------------------------------------------------------------------ device flow

    alias HttpPost = Proc(String, Hash(String, String), {Int32, Hash(String, JSON::Any)})

    # Form-encoded POST returning (status, parsed JSON).
    def self._default_http_post(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)}
      headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"}
      response = HTTP::Client.post(url, headers: headers, body: URI::Params.encode(data))
      payload = response.body.empty? ? {} of String => JSON::Any : JSON.parse(response.body).as_h
      {response.status_code, payload}
    end

    # One OAuth provider's device-grant endpoints (RFC 8628). `http_post`
    # is injectable so the full flow is testable offline.
    struct OAuthDeviceFlow
      getter provider : String
      getter client_id : String
      getter device_authorization_endpoint : String
      getter token_endpoint : String
      getter scope : String
      getter client_secret : String
      @http_post : HttpPost

      def initialize(
        @provider : String,
        @client_id : String,
        @device_authorization_endpoint : String,
        @token_endpoint : String,
        @scope : String = "",
        @client_secret : String = "",
        @http_post : HttpPost = ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} { Managed._default_http_post(url, data) },
      )
      end

      # Begin the flow; returns the RFC 8628 response.
      def start : Hash(String, JSON::Any)
        data = {"client_id" => client_id}
        data["scope"] = scope if !scope.empty?
        status, payload = @http_post.call(device_authorization_endpoint, data)
        if status != 200 || !payload.has_key?("device_code")
          raise Chronicle::Packs::PackError.new(
            "device authorization failed for #{provider.inspect}: HTTP #{status} #{payload["error"]?.try(&.as_s?) || ""}"
          )
        end
        payload
      end

      # One poll of the token endpoint.
      def poll(device_code : String) : Hash(String, JSON::Any)
        data = {
          "grant_type"  => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => device_code,
          "client_id"   => client_id,
        }
        data["client_secret"] = client_secret if !client_secret.empty?
        status, payload = @http_post.call(token_endpoint, data)
        if status == 200 && payload.has_key?("access_token")
          return {"status" => JSON::Any.new("ok"), "token" => JSON::Any.new(payload)}
        end
        error = payload["error"]?.try(&.as_s?) || "http_#{status}"
        if error.in?({"authorization_pending", "slow_down"})
          return {"status" => JSON::Any.new("pending"), "error" => JSON::Any.new(error)}
        end
        {"status" => JSON::Any.new("error"), "error" => JSON::Any.new(error)}
      end

      # Exchange a refresh token; nil on terminal refresh failure.
      def refresh(refresh_token : String) : Hash(String, JSON::Any)?
        data = {"grant_type" => "refresh_token", "refresh_token" => refresh_token, "client_id" => client_id}
        data["client_secret"] = client_secret if !client_secret.empty?
        status, payload = @http_post.call(token_endpoint, data)
        status == 200 && payload.has_key?("access_token") ? payload : nil
      end
    end

    # ------------------------------------------------------------------ the source

    # Resolves credential names from the token store, refreshing expired
    # tokens through their provider's flow when possible.
    class OAuthCredentialSource < CredentialSource
      # Refresh this many seconds before nominal expiry.
      EXPIRY_MARGIN = 60.0

      getter store : OAuthTokenStore
      getter flows : Hash(String, OAuthDeviceFlow)
      @now_fn : Proc(Float64)

      def initialize(
        @store : OAuthTokenStore,
        @flows : Hash(String, OAuthDeviceFlow) = {} of String => OAuthDeviceFlow,
        @now_fn : Proc(Float64) = -> { Time.utc.to_unix_f },
      )
      end

      def label : String
        "oauth_token_store"
      end

      def add_flow(credential_name : String, flow : OAuthDeviceFlow) : Nil
        flows[credential_name] = flow
      end

      def resolve(credential_name : String) : String?
        record = store.get(credential_name)
        return nil if record.nil?

        if expires_at = record["expires_at"]?.try(&.as_f?)
          if @now_fn.call >= expires_at - EXPIRY_MARGIN
            return _refresh(credential_name, record)
          end
        end
        record["access_token"].as_s?
      end

      private def _refresh(credential_name : String, record : Hash(String, JSON::Any)) : String?
        refresh_token = record["refresh_token"]?.try(&.as_s?)
        flow = flows[credential_name]?
        return nil if refresh_token.nil? || flow.nil?

        payload = flow.refresh(refresh_token)
        return nil if payload.nil? # dead grant; resolve fails closed

        store.put(
          credential_name,
          access_token: payload["access_token"].as_s,
          refresh_token: payload["refresh_token"]?.try(&.as_s?) || refresh_token,
          expires_in: payload["expires_in"]?.try(&.as_f?),
          token_type: payload["token_type"]?.try(&.as_s?) || record["token_type"]?.try(&.as_s?) || "Bearer",
          scope: payload["scope"]?.try(&.as_s?) || record["scope"]?.try(&.as_s?) || "",
          provider: record["provider"]?.try(&.as_s?) || "",
          now: @now_fn.call,
        )
        payload["access_token"].as_s?
      end
    end
  end
end

require "spec"
require "../spec_helper"

# Secrets pack (packs/secrets): credential reference management — names only,
# never secret values. Ported from upstream packs/secrets/*
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no API key.

module SecretsSpecSupport
  extend self

  class ExplodingSource < Chronicle::Packs::Secrets::Managed::CredentialSource
    def label : String
      "exploding"
    end

    def resolve(credential_name : String) : String?
      raise "down"
    end
  end

  REPO = Path[__DIR__].parent.parent

  def secrets_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "secrets" / "manifest.toml"
  end

  def secrets_settings(json : String) : Chronicle::Packs::Secrets::SecretsSettings
    Chronicle::Packs::Secrets::SecretsSettings.from_json(json)
  end

  def with_secrets_runtime(custom_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if custom_settings
      rt.load_pack(Chronicle::Packs::Secrets.pack, JSON.parse(custom_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::Secrets.pack).should be_true
    end
    Chronicle::Packs::Secrets::Managed.clear_credential_sources
    yield store, graph, rt
  ensure
    Chronicle::Packs::Secrets::Managed.clear_credential_sources
  end

  def with_env_vars(vars : Hash(String, String), &)
    previous = {} of String => String?
    vars.each_key do |name|
      previous[name] = ENV[name]?
      ENV[name] = vars[name]
    end
    begin
      yield
    ensure
      previous.each do |name, value|
        if value
          ENV[name] = value
        else
          ENV.delete(name)
        end
      end
    end
  end
end

include SecretsSpecSupport

describe Chronicle::Packs::Secrets do
  describe "manifest-declared surface" do
    it "matches the upstream secrets manifest" do
      pack = Chronicle::Packs::Secrets.pack
      pack.name.should eq("secrets")
      pack.version.should eq("0.2.0")
      pack.object_types.map(&.name).should eq(
        ["secret_scope", "credential_ref", "secret_usage_event", "credential_rotation_event"]
      )
      pack.relation_types.map(&.name).should eq(["credential_used_in", "governed_by"])
      pack.behaviors.map(&.name).should eq(["secret_usage_recorder", "credential_resolution_recorder"])
      pack.tools.map(&.name).should eq(["resolve_credential"])
      pack.settings_schema.should eq("SecretsSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(secrets_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Secrets.pack)
    end
  end

  describe "resolve_credential_fn" do
    it "resolves from the environment first" do
      with_env_vars({"MYAPP_OPENAI_KEY" => "sk-fake-value"}) do
        Chronicle::Packs::Secrets.resolve_credential_fn("OPENAI_KEY", "MYAPP_").should eq("sk-fake-value")
      end
    end

    it "reports the source label" do
      with_env_vars({"MYAPP_OPENAI_KEY" => "sk-fake-value"}) do
        value, source = Chronicle::Packs::Secrets.resolve_credential_with_source_fn("OPENAI_KEY", "MYAPP_")
        value.should eq("sk-fake-value")
        source.should eq("env")
      end
    end

    it "returns nil when unresolved" do
      with_env_vars({} of String => String) do
        Chronicle::Packs::Secrets.resolve_credential_fn("NOPE_KEY").should be_nil
        value, source = Chronicle::Packs::Secrets.resolve_credential_with_source_fn("NOPE_KEY")
        value.should be_nil
        source.should be_nil
      end
    end

    it "consults registered managed sources after env" do
      with_env_vars({} of String => String) do
        source = SecretsSpecFakeSource.new("oauth_token_store", {"GMAIL_TOKEN" => "ya29.fake"})
        Chronicle::Packs::Secrets::Managed.register_credential_source(source)
        value, label = Chronicle::Packs::Secrets.resolve_credential_with_source_fn("GMAIL_TOKEN")
        value.should eq("ya29.fake")
        label.should eq("oauth_token_store")
      end
    end

    it "env always wins over a managed source" do
      with_env_vars({"GMAIL_TOKEN" => "env-value"}) do
        source = SecretsSpecFakeSource.new("oauth_token_store", {"GMAIL_TOKEN" => "store-value"})
        Chronicle::Packs::Secrets::Managed.register_credential_source(source)
        Chronicle::Packs::Secrets.resolve_credential_fn("GMAIL_TOKEN").should eq("env-value")
      end
    end
  end

  describe "managed source seam" do
    it "registers, lists, and clears sources" do
      Chronicle::Packs::Secrets::Managed.clear_credential_sources
      Chronicle::Packs::Secrets::Managed.registered_credential_sources.should be_empty
      source = SecretsSpecFakeSource.new("fake", {} of String => String)
      Chronicle::Packs::Secrets::Managed.register_credential_source(source)
      Chronicle::Packs::Secrets::Managed.registered_credential_sources.size.should eq(1)
      Chronicle::Packs::Secrets::Managed.clear_credential_sources
      Chronicle::Packs::Secrets::Managed.registered_credential_sources.should be_empty
    end

    it "continues after a broken source" do
      Chronicle::Packs::Secrets::Managed.register_credential_source(ExplodingSource.new)
      Chronicle::Packs::Secrets::Managed.register_credential_source(SecretsSpecFakeSource.new("fallback", {"K" => "value"}))
      Chronicle::Packs::Secrets.resolve_credential_fn("K").should eq("value")
    end
  end

  describe "OAuthCredentialSource" do
    it "returns a stored non-expired token" do
      store = Chronicle::Packs::Secrets::Managed::OAuthTokenStore.new(":memory:")
      store.put("GMAIL_TOKEN", access_token: "ya29.abc", expires_in: 3600.0, now: 1000.0)
      source = Chronicle::Packs::Secrets::Managed::OAuthCredentialSource.new(store, now_fn: -> { 1001.0 })
      source.resolve("GMAIL_TOKEN").should eq("ya29.abc")
    end

    it "refreshes an expired token through its provider flow" do
      store = Chronicle::Packs::Secrets::Managed::OAuthTokenStore.new(":memory:")
      store.put("GMAIL_TOKEN", access_token: "ya29.old", refresh_token: "rt1", expires_in: 10.0, now: 1000.0)
      flow = Chronicle::Packs::Secrets::Managed::OAuthDeviceFlow.new(
        provider: "gmail", client_id: "cid",
        device_authorization_endpoint: "https://example.com/device",
        token_endpoint: "https://example.com/token",
        http_post: ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} {
          {200, {"access_token" => JSON::Any.new("ya29.new"), "refresh_token" => JSON::Any.new("rt2"), "expires_in" => JSON::Any.new(3600)}}
        },
      )
      source = Chronicle::Packs::Secrets::Managed::OAuthCredentialSource.new(store, flows: {"GMAIL_TOKEN" => flow}, now_fn: -> { 2000.0 })
      source.resolve("GMAIL_TOKEN").should eq("ya29.new")
      store.get("GMAIL_TOKEN").not_nil!["refresh_token"].as_s.should eq("rt2")
    end

    it "fails closed on an expired token with no refresh path" do
      store = Chronicle::Packs::Secrets::Managed::OAuthTokenStore.new(":memory:")
      store.put("GMAIL_TOKEN", access_token: "ya29.old", expires_in: 10.0, now: 1000.0)
      source = Chronicle::Packs::Secrets::Managed::OAuthCredentialSource.new(store, now_fn: -> { 2000.0 })
      source.resolve("GMAIL_TOKEN").should be_nil
    end

    it "fails closed when a refresh grant is rejected" do
      store = Chronicle::Packs::Secrets::Managed::OAuthTokenStore.new(":memory:")
      store.put("GMAIL_TOKEN", access_token: "old", refresh_token: "rt1", expires_in: 10.0, now: 1000.0)
      flow = Chronicle::Packs::Secrets::Managed::OAuthDeviceFlow.new(provider: "gmail", client_id: "cid", device_authorization_endpoint: "https://example.com/device", token_endpoint: "https://example.com/token", http_post: ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} { {400, {"error" => JSON::Any.new("invalid_grant")}} })
      Chronicle::Packs::Secrets::Managed::OAuthCredentialSource.new(store, flows: {"GMAIL_TOKEN" => flow}, now_fn: -> { 2000.0 }).resolve("GMAIL_TOKEN").should be_nil
    end

    it "returns nil for an unknown credential" do
      store = Chronicle::Packs::Secrets::Managed::OAuthTokenStore.new(":memory:")
      source = Chronicle::Packs::Secrets::Managed::OAuthCredentialSource.new(store)
      source.resolve("NOPE").should be_nil
    end
  end

  describe "OAuthDeviceFlow" do
    it "starts the device flow and polls to completion" do
      calls = [] of String
      flow = Chronicle::Packs::Secrets::Managed::OAuthDeviceFlow.new(
        provider: "gmail", client_id: "cid",
        device_authorization_endpoint: "https://example.com/device",
        token_endpoint: "https://example.com/token",
        http_post: ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} {
          calls << url
          if url.ends_with?("/device")
            {200, {"device_code" => JSON::Any.new("dc1"), "user_code" => JSON::Any.new("uc1"), "verification_uri" => JSON::Any.new("https://example.com/verify"), "interval" => JSON::Any.new(5), "expires_in" => JSON::Any.new(1800)}}
          else
            {200, {"access_token" => JSON::Any.new("ya29.new"), "refresh_token" => JSON::Any.new("rt1")}}
          end
        },
      )
      started = flow.start
      started["device_code"].as_s.should eq("dc1")
      result = flow.poll("dc1")
      result["status"].as_s.should eq("ok")
      result["token"].as_h["access_token"].as_s.should eq("ya29.new")
    end

    it "reports pending while the owner has not approved" do
      flow = Chronicle::Packs::Secrets::Managed::OAuthDeviceFlow.new(
        provider: "gmail", client_id: "cid",
        device_authorization_endpoint: "https://example.com/device",
        token_endpoint: "https://example.com/token",
        http_post: ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} {
          {400, {"error" => JSON::Any.new("authorization_pending")}}
        },
      )
      result = flow.poll("dc1")
      result["status"].as_s.should eq("pending")
    end

    it "reports terminal provider errors" do
      flow = Chronicle::Packs::Secrets::Managed::OAuthDeviceFlow.new(provider: "gmail", client_id: "cid", device_authorization_endpoint: "https://example.com/device", token_endpoint: "https://example.com/token", http_post: ->(url : String, data : Hash(String, String)) : {Int32, Hash(String, JSON::Any)} { {400, {"error" => JSON::Any.new("access_denied")}} })
      result = flow.poll("dc1")
      result["status"].as_s.should eq("error")
      result["error"].as_s.should eq("access_denied")
    end
  end

  describe "behaviors" do
    it "records a registration usage event on credential_ref.created" do
      with_secrets_runtime do |_store, graph, rt|
        graph.add_object("credential_ref", %({"name":"OPENAI_KEY","scope":"write"}))
        rt.run_until_idle

        events = graph.objects(type: "secret_usage_event")
        events.size.should eq(1)
        data = JSON.parse(events.first.data)
        data["credential_ref_name"].as_s.should eq("OPENAI_KEY")
        data["resolved"].as_bool.should be_false
        data["metadata"].as_h["event_type"].as_s.should eq("registered")
      end
    end

    it "patches credential_ref use stats on a resolved usage event" do
      with_secrets_runtime do |_store, graph, rt|
        ref = graph.add_object("credential_ref", %({"name":"OPENAI_KEY","scope":"write","use_count":0}))
        rt.run_until_idle
        graph.objects(type: "secret_usage_event").clear

        graph.add_object("secret_usage_event", JSON.build do |json|
          json.object do
            json.field "credential_ref_name", "OPENAI_KEY"
            json.field "resolved", true
            json.field "metadata", {"event_type" => JSON::Any.new("resolved"), "credential_ref_id" => JSON::Any.new(ref.id)}
          end
        end)
        rt.run_until_idle

        ref_data = JSON.parse(graph.get_object(ref.id).not_nil!.data)
        ref_data["use_count"].as_i.should eq(1)
        ref_data["last_used_at"].should_not be_nil
      end
    end

    it "does not patch on registration events" do
      with_secrets_runtime do |_store, graph, rt|
        ref = graph.add_object("credential_ref", %({"name":"OPENAI_KEY","use_count":0}))
        rt.run_until_idle
        graph.objects(type: "secret_usage_event").clear

        graph.add_object("secret_usage_event", JSON.build do |json|
          json.object do
            json.field "credential_ref_name", "OPENAI_KEY"
            json.field "resolved", false
            json.field "metadata", {"event_type" => JSON::Any.new("registered"), "credential_ref_id" => JSON::Any.new(ref.id)}
          end
        end)
        rt.run_until_idle

        JSON.parse(graph.get_object(ref.id).not_nil!.data)["use_count"].as_i.should eq(0)
      end
    end
  end

  describe "resolve_and_audit_fn" do
    it "resolves and records a usage event that updates the ref" do
      with_secrets_runtime do |_store, graph, rt|
        ref = graph.add_object("credential_ref", %({"name":"OPENAI_KEY","use_count":0}))
        rt.run_until_idle
        graph.objects(type: "secret_usage_event").clear

        value = nil
        with_env_vars({"MYAPP_OPENAI_KEY" => "sk-live"}) do
          value = Chronicle::Packs::Secrets.resolve_and_audit_fn(graph, "OPENAI_KEY", "MYAPP_", "my_behavior", credential_ref_id: ref.id)
          rt.run_until_idle
        end

        value.should eq("sk-live")
        resolved_events = graph.objects(type: "secret_usage_event").select do |event|
          JSON.parse(event.data)["metadata"].as_h["event_type"].as_s == "resolved"
        end
        resolved_events.size.should eq(1)
        JSON.parse(resolved_events.first.data)["metadata"].as_h["event_type"].as_s.should eq("resolved")

        ref_data = JSON.parse(graph.get_object(ref.id).not_nil!.data)
        ref_data["use_count"].as_i.should eq(1)
      end
    end
  end
end

# A fake managed source for resolution tests.
class SecretsSpecFakeSource < Chronicle::Packs::Secrets::Managed::CredentialSource
  getter label : String

  def initialize(@label : String, @values : Hash(String, String))
  end

  def resolve(credential_name : String) : String?
    @values[credential_name]?
  end
end

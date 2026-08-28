require "spec"
require "json"
require "../spec_helper"

# Composio Pack (packs/composio): an optional thin Composio route — hosted
# Connect Links and per-service connection status. It never mirrors the
# Composio catalog or becomes a canonical service identity. No object or
# relation types; two proposal tools + gateway capabilities behind an
# injectable transport seam. Translated from upstream packs/composio/*
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0).

# The injectable transport the fixtures use (mirrors upstream
# fixtures/run_fixtures.py FixtureTransport).
class ComposioFixtureTransport < Chronicle::Packs::Composio::ComposioTransport
  def authorize(*, user_id : String, toolkit : String, callback_url : String) : Hash(String, JSON::Any)
    {"id" => JSON::Any.new("conn_req_fixture"), "redirect_url" => JSON::Any.new("https://connect.composio.dev/link/fixture"), "status" => JSON::Any.new("INITIATED")} of String => JSON::Any
  end

  def list_connections(*, user_id : String, toolkit : String, limit : Int32) : Array(Hash(String, JSON::Any))
    [{"id" => JSON::Any.new("ca_fixture"), "status" => JSON::Any.new("ACTIVE"), "toolkit_slug" => JSON::Any.new(toolkit)} of String => JSON::Any]
  end

  def execute(*, tool_slug : String, arguments : Hash(String, JSON::Any), user_id : String, connected_account_id : String, version : String) : Hash(String, JSON::Any)
    {"successful" => JSON::Any.new(true), "data" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
  end

  def resolve_tool(*, toolkit : String, candidates : Array(String), requested_version : String) : Hash(String, JSON::Any)
    {"tool_slug" => JSON::Any.new(candidates.first?), "version" => JSON::Any.new(requested_version), "resolution" => JSON::Any.new("fixture")} of String => JSON::Any
  end
end

module ComposioSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def composio_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "composio" / "manifest.toml"
  end

  def with_composio_runtime(transport : Chronicle::Packs::Composio::ComposioTransport? = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    Chronicle::Packs::ToolGateway.clear_local_registry
    Chronicle::Packs::Composio.configure_composio_transport(transport)
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    rt.load_pack(Chronicle::Packs::Composio.pack).should be_true
    Chronicle::Packs::Composio.register_composio_capabilities
    yield store, graph, rt
  ensure
    Chronicle::Packs::Composio.configure_composio_transport(nil)
    Chronicle::Packs::ToolGateway.clear_local_registry
  end
end

include ComposioSpecSupport

describe Chronicle::Packs::Composio do
  describe "manifest-declared surface" do
    it "matches the upstream composio manifest" do
      pack = Chronicle::Packs::Composio.pack
      pack.name.should eq("composio")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should be_empty
      pack.relation_types.map(&.name).should be_empty
      pack.behaviors.map(&.name).should be_empty
      pack.tools.map(&.name).should eq(["request_composio_link", "request_composio_status"])
      pack.settings_schema.should eq("ComposioSettings")
      pack.capabilities.map(&.capability).should eq(["connections.link", "connections.status"])
      pack.capabilities.map(&.risk_class).should eq(["high", "low"])
      pack.capabilities.map(&.action_class).should eq(["R4", "R0"])
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(composio_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Composio.pack)
    end
  end

  describe "resolve_catalog_tool" do
    it "harden canonical candidates into one concrete provider tool version" do
      rows = [
        {
          "slug"               => JSON::Any.new("gmail_send_email"),
          "toolkit"            => JSON::Any.new({"slug" => JSON::Any.new("gmail")}),
          "version"            => JSON::Any.new("1.2.3"),
          "available_versions" => JSON::Any.new([JSON::Any.new("1.0.0"), JSON::Any.new("1.2.3")]),
          "input_parameters"   => JSON::Any.new({"properties" => JSON::Any.new({"to" => JSON::Any.new({} of String => JSON::Any)})}),
        } of String => JSON::Any,
      ]
      result = Chronicle::Packs::Composio.resolve_catalog_tool(rows, toolkit: "gmail", candidates: ["gmail_send_email"])
      result["tool_slug"].as_s.should eq("gmail_send_email")
      result["version"].as_s.should eq("1.2.3")
      result["resolution"].as_s.should eq("catalog")
      result["input_schema_fingerprint"].as_s.should start_with("sha256:")
    end

    it "selects a requested available version" do
      rows = [
        {
          "slug"               => JSON::Any.new("github_create_issue"),
          "toolkit"            => JSON::Any.new("github"),
          "version"            => JSON::Any.new("2.0.0"),
          "available_versions" => JSON::Any.new([JSON::Any.new("1.9.0"), JSON::Any.new("2.0.0")]),
        } of String => JSON::Any,
      ]
      result = Chronicle::Packs::Composio.resolve_catalog_tool(rows, toolkit: "github", candidates: ["github_create_issue"], requested_version: "1.9.0")
      result["version"].as_s.should eq("1.9.0")
    end

    it "fails closed with no configured candidates or an unknown candidate" do
      expect_raises(Chronicle::Packs::Composio::ComposioUnavailable, /no provider tool candidates/) do
        Chronicle::Packs::Composio.resolve_catalog_tool([] of Hash(String, JSON::Any), toolkit: "gmail", candidates: ["  "])
      end
      expect_raises(Chronicle::Packs::Composio::ComposioUnavailable, /contains none of the configured tools/) do
        Chronicle::Packs::Composio.resolve_catalog_tool([] of Hash(String, JSON::Any), toolkit: "gmail", candidates: ["gmail_send_email"])
      end
    end

    it "fails closed on a deprecated tool" do
      rows = [
        {
          "slug"          => JSON::Any.new("legacy_tool"),
          "toolkit"       => JSON::Any.new("gmail"),
          "version"       => JSON::Any.new("0.9.0"),
          "is_deprecated" => JSON::Any.new(true),
        } of String => JSON::Any,
      ]
      expect_raises(Chronicle::Packs::Composio::ComposioUnavailable, /is deprecated/) do
        Chronicle::Packs::Composio.resolve_catalog_tool(rows, toolkit: "gmail", candidates: ["legacy_tool"])
      end
    end
  end

  describe "redirect handling" do
    it "stores a Connect Link without leaking the bearer-like URL into graph output" do
      safe = Chronicle::Packs::Composio.store_redirect("conn_req_1", "https://connect.composio.dev/link/abc123")
      safe["connection_request_id"].as_s.should eq("conn_req_1")
      safe["redirect_origin"].as_s.should eq("https://connect.composio.dev")
      safe["redirect_url_fingerprint"].as_s.should start_with("sha256:")
      Chronicle::Packs::Composio.take_redirect("conn_req_1").should eq("https://connect.composio.dev/link/abc123")
      Chronicle::Packs::Composio.take_redirect("conn_req_1").should be_nil
    end

    it "rejects a non-https or empty Connect Link" do
      expect_raises(Exception, /Composio returned no connection request id or redirect URL/) do
        Chronicle::Packs::Composio.store_redirect("", "")
      end
      expect_raises(Exception, /invalid Connect Link/) do
        Chronicle::Packs::Composio.store_redirect("req", "ftp://example.com/link")
      end
    end
  end

  describe "connection_summary" do
    it "keeps only non-secret account identity/status fields" do
      row = {
        "id"           => JSON::Any.new("ca_1"),
        "status"       => JSON::Any.new("active"),
        "toolkit"      => JSON::Any.new({"slug" => JSON::Any.new("gmail")}),
        "created_at"   => JSON::Any.new("2026-01-01"),
        "updated_at"   => JSON::Any.new("2026-02-01"),
        "access_token" => JSON::Any.new("super-secret"),
      } of String => JSON::Any
      summary = Chronicle::Packs::Composio.connection_summary(row)
      summary["id"].as_s.should eq("ca_1")
      summary["status"].as_s.should eq("ACTIVE")
      summary["toolkit"].as_s.should eq("gmail")
      summary.has_key?("access_token").should be_false
    end
  end

  describe "fixture: Connect Link proposal → approval → execution" do
    it "proposes connections.link (R4/high), holds, approves, executes through the transport, and stores the redirect" do
      with_composio_runtime(ComposioFixtureTransport.new) do |_store, graph, rt|
        call = Chronicle::Packs::Composio.request_composio_link_fn(
          graph,
          user_id: "fixture:owner",
          service: "gmail",
          callback_url: "http://localhost/return",
        )
        rt.run_until_idle

        call_data = JSON.parse(graph.get_object(call.id).not_nil!.data)
        call_data["capability_name"].as_s.should eq("connections.link")
        call_data["risk_class"].as_s.should eq("high")
        call_data["action_class"].as_s.should eq("R4")
        call_data["status"].as_s.should eq("policy_checking")

        approved = Chronicle::Packs::ToolGateway.approve_capability_fn(graph, call.id, approver_ref: "fixture:owner")
        approved["ok"].as_bool.should be_true
        rt.run_until_idle

        result = graph.objects(type: "capability_result").find { |obj| JSON.parse(obj.data)["call_id"].as_s == call.id }
        result.should_not be_nil
        output = JSON.parse(result.not_nil!.data)["output_data"].as_s
        output.should contain("connect.composio.dev")
        output.should_not contain("/link/fixture")

        redirect = Chronicle::Packs::Composio.take_redirect("conn_req_fixture")
        redirect.should eq("https://connect.composio.dev/link/fixture")
      end
    end

    it "proposes connections.status (R0/low) as a read-only call" do
      with_composio_runtime(ComposioFixtureTransport.new) do |_store, graph, rt|
        call = Chronicle::Packs::Composio.request_composio_status_fn(graph, user_id: "fixture:owner", service: "gmail", limit: 10)
        rt.run_until_idle

        call_data = JSON.parse(graph.get_object(call.id).not_nil!.data)
        call_data["capability_name"].as_s.should eq("connections.status")
        call_data["risk_class"].as_s.should eq("low")
        call_data["action_class"].as_s.should eq("R0")
        call_data["status"].as_s.should eq("done")

        result = graph.objects(type: "capability_result").find { |obj| JSON.parse(obj.data)["call_id"].as_s == call.id }
        result.should_not be_nil
        JSON.parse(result.not_nil!.data)["output_data"].as_s.should contain("ca_fixture")
      end
    end
  end

  describe "transport seam" do
    it "composio_transport returns the configured transport and fails closed without one" do
      Chronicle::Packs::Composio.configure_composio_transport(ComposioFixtureTransport.new)
      Chronicle::Packs::Composio.composio_transport.should be_a(Chronicle::Packs::Composio::ComposioTransport)
      Chronicle::Packs::Composio.configure_composio_transport(nil)
      expect_raises(Chronicle::Packs::Composio::ComposioUnavailable) do
        Chronicle::Packs::Composio.composio_transport
      end
    ensure
      Chronicle::Packs::Composio.configure_composio_transport(nil)
    end

    it "_link_service returns ok with the safe redirect, _connection_status returns the summary rows" do
      Chronicle::Packs::Composio.configure_composio_transport(ComposioFixtureTransport.new)
      linked = Chronicle::Packs::Composio._link_service(
        {"user_id" => JSON::Any.new("u1"), "service" => JSON::Any.new("gmail"), "callback_url" => JSON::Any.new("http://localhost/return")},
        api_key_env: "COMPOSIO_API_KEY",
      )
      linked["ok"].as_bool.should be_true
      linked["redirect_origin"].as_s.should eq("https://connect.composio.dev")

      status = Chronicle::Packs::Composio._connection_status(
        {"user_id" => JSON::Any.new("u1"), "service" => JSON::Any.new("gmail"), "limit" => JSON::Any.new(25)},
        api_key_env: "COMPOSIO_API_KEY",
      )
      status["ok"].as_bool.should be_true
      status["connections"].as_a.size.should eq(1)
      status["connections"].as_a.first.as_h["status"].as_s.should eq("ACTIVE")
    ensure
      Chronicle::Packs::Composio.configure_composio_transport(nil)
    end
  end
end

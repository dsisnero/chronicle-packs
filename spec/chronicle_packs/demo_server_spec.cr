require "spec"
require "../spec_helper"

# Demo server (upstream packs/demo_server.py) — the HTTP REST surface over
# the assembled stack. The port keeps the module-level helpers and the
# Handler dispatch as an in-process `Chronicle::Packs::DemoServer` module:
# a runtime is built over a memory store with the assistant bundle, and the
# endpoints are driven directly (the port's analog of upstream's
# `_EXECUTOR.run` — no subprocess, no socket dependency in tests).
#
# Divergences (see parity.md):
# - Runtime state is module-level but constructed lazily via
#   `DemoServer.reset_runtime`; tests build a fresh runtime and a Handler
#   bound to it instead of a process singleton.
# - `_build_runtime` uses the ported `Bundles.build_assistant` over a memory
#   store (upstream persists to a SQLite event-log file and resumes via
#   Runtime.load); the endpoint surface is unchanged.
# - Endpoints needing deferred seams (OAuth managed source, MCP outbound
#   registration, evolution boot) return the same 4xx/5xx shapes with a
#   clear message when the seam is not wired.

module DemoServerSpecSupport
  extend self

  def hermetic
    Chronicle::Packs::Conftest.hermetic_environment
  end

  # Build a fresh demo runtime + Handler bound to it.
  # Wrap a plain Hash(String, String) body into a JSON::Any hash for the
  # in-process dispatch.
  def body(h : Hash(String, String)) : Hash(String, JSON::Any)
    h.to_h.transform_values { |v| JSON::Any.new(v) }
  end

  def handler : {Chronicle::Packs::DemoServer::Handler, Chronicle::GraphProjection, Chronicle::Runtime(Chronicle::Packs::Bundles::BundleModel)}
    rt = Chronicle::Packs::DemoServer.reset_runtime
    graph = rt.graph.not_nil!
    {Chronicle::Packs::DemoServer::Handler.new(rt), graph, rt}
  end
end

include DemoServerSpecSupport

describe Chronicle::Packs::DemoServer do
  describe "check_approval_auth" do
    it "passes with a matching bearer token and records no denial" do
      store = Chronicle::MemoryEventStore.new
      graph = Chronicle::GraphProjection.empty.attach_store(store)
      ok, reason = Chronicle::Packs::DemoServer.check_approval_auth(
        graph,
        "Bearer secret-token",
        evolution_on: true,
        token: "secret-token",
      )
      ok.should be_true
      reason.should eq("")
      graph.objects(type: "approval_auth_denial").size.should eq(0)
    end

    it "refuses on token mismatch and audits the denial" do
      store = Chronicle::MemoryEventStore.new
      graph = Chronicle::GraphProjection.empty.attach_store(store)
      ok, reason = Chronicle::Packs::DemoServer.check_approval_auth(
        graph,
        "Bearer wrong",
        evolution_on: true,
        token: "secret-token",
      )
      ok.should be_false
      reason.should contain("bearer token mismatch")
      denials = graph.objects(type: "approval_auth_denial")
      denials.size.should eq(1)
      JSON.parse(denials.first.data)["reason"].as_s.should eq(reason)
      JSON.parse(denials.first.data)["path"].as_s.should eq("/approvals")
    end

    it "refuses missing token and audits the denial" do
      store = Chronicle::MemoryEventStore.new
      graph = Chronicle::GraphProjection.empty.attach_store(store)
      ok, reason = Chronicle::Packs::DemoServer.check_approval_auth(
        graph,
        "",
        evolution_on: true,
        token: "secret-token",
      )
      ok.should be_false
      reason.should contain("missing")
      graph.objects(type: "approval_auth_denial").size.should eq(1)
    end

    it "refuses when evolution is on and no token is configured" do
      store = Chronicle::MemoryEventStore.new
      graph = Chronicle::GraphProjection.empty.attach_store(store)
      ok, reason = Chronicle::Packs::DemoServer.check_approval_auth(
        graph,
        "Bearer anything",
        evolution_on: true,
        token: "",
      )
      ok.should be_false
      reason.should contain("ACTIVEGRAPH_APPROVAL_TOKEN")
      graph.objects(type: "approval_auth_denial").size.should eq(1)
    end

    it "stays open with no token and no evolution, and records no denial" do
      store = Chronicle::MemoryEventStore.new
      graph = Chronicle::GraphProjection.empty.attach_store(store)
      ok, reason = Chronicle::Packs::DemoServer.check_approval_auth(graph, "", evolution_on: false, token: "")
      ok.should be_true
      reason.should eq("")
      graph.objects(type: "approval_auth_denial").size.should eq(0)
    end
  end

  describe "serialization helpers" do
    it "_safe_json converts arbitrary values to JSON-safe primitives" do
      Chronicle::Packs::DemoServer._safe_json(JSON.parse(%({"a":1,"b":["x"],"c":null}))).should eq(JSON.parse(%({"a":1,"b":["x"],"c":null})))
    end

    it "_ts returns an ISO-8601 UTC timestamp" do
      ts = Chronicle::Packs::DemoServer._ts
      ts.should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    end

    it "_profile_payload reports exists=false when no profile is registered" do
      hermetic
      _h, graph, _rt = handler
      payload = Chronicle::Packs::DemoServer._profile_payload(graph)
      payload["exists"].as_bool.should be_false
    end

    it "_active_profile_id returns nil when no profile exists" do
      hermetic
      _h, graph, _rt = handler
      Chronicle::Packs::DemoServer._active_profile_id(graph).should be_nil
    end
  end

  describe "profile lifecycle (GET/POST /profile, goals, instructions, personality)" do
    it "seeds the default profile and reports exists=true" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      body = JSON.parse(h.response_body.not_nil!)
      body["exists"].as_bool.should be_true
      body["profile"].as_h["name"].as_s.should_not be_empty
    end

    it "updates the profile identity fields" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_post(body({"name" => "Aria", "mission" => "Help Alice."}))
      body = JSON.parse(h.response_body.not_nil!)
      body["profile"].as_h["name"].as_s.should eq("Aria")
      body["profile"].as_h["mission"].as_s.should eq("Help Alice.")
    end

    it "adds a goal and lists it in the payload" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_goal_post(body({"text" => "Close the seed round.", "priority" => "high"}))
      body = JSON.parse(h.response_body.not_nil!)
      goals = body["goals"].as_a
      goals.size.should eq(1)
      goals.first["text"].as_s.should eq("Close the seed round.")
      goals.first["priority"].as_s.should eq("high")
    end

    it "rejects an invalid goal priority" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_goal_post(body({"text" => "x", "priority" => "bogus"}))
      h.response_status.should eq(400)
      JSON.parse(h.response_body.not_nil!)["error"].as_s.should contain("priority")
    end

    it "deletes a goal" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_goal_post(body({"text" => "Temporary goal."}))
      gid = JSON.parse(h.response_body.not_nil!)["goals"].as_a.first["id"].as_s
      h._handle_profile_goal_delete(body({"id" => gid}))
      JSON.parse(h.response_body.not_nil!)["goals"].as_a.size.should eq(0)
    end

    it "adds a standing instruction and lists it" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_instruction_post(body({"text" => "Lead with the answer.", "scope" => "global"}))
      body = JSON.parse(h.response_body.not_nil!)
      instructions = body["instructions"].as_a
      instructions.size.should eq(1)
      instructions.first["text"].as_s.should eq("Lead with the answer.")
    end

    it "rejects an out-of-range instruction priority" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_instruction_post({"text" => JSON::Any.new("x"), "priority" => JSON::Any.new(150)})
      h.response_status.should eq(400)
    end

    it "upserts the global personality" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_personality_post(body({"tone" => "direct", "verbosity" => "concise"}))
      body = JSON.parse(h.response_body.not_nil!)
      body["personality"].as_h["tone"].as_s.should eq("direct")
    end

    it "rejects an invalid tone" do
      hermetic
      h, _graph, _rt = handler
      h._handle_profile_seed
      h._handle_profile_personality_post(body({"tone" => "aggressive"}))
      h.response_status.should eq(400)
    end
  end

  describe "summary/graph/trace/packs endpoints" do
    it "GET /summary reports counts" do
      hermetic
      h, _graph, _rt = handler
      h._handle_summary
      body = JSON.parse(h.response_body.not_nil!)
      body["runtime_ready"].as_bool.should be_true
      body["object_count"].as_i.should be >= 0
      body["relation_count"].as_i.should be >= 0
    end

    it "GET /graph lists objects and relations" do
      hermetic
      h, graph, _rt = handler
      graph.add_object("source", %({"kind":"chat_message","content":"hello","channel":"chat","sender_ref":"user:alice"}))
      h._handle_graph({} of String => String)
      body = JSON.parse(h.response_body.not_nil!)
      body["object_count"].as_i.should be >= 1
      types = body["objects"].as_a.map { |o| o["type"].as_s }
      types.should contain("source")
    end

    it "GET /trace lists events with pagination" do
      hermetic
      h, graph, rt = handler
      graph.add_object("source", %({"kind":"chat_message","content":"hi","channel":"chat","sender_ref":"user:alice"}))
      rt.run_until_idle
      h._handle_trace({"limit" => "10", "offset" => "0"})
      body = JSON.parse(h.response_body.not_nil!)
      body["total"].as_i.should be >= 1
      body["events"].as_a.size.should be >= 1
    end

    it "GET /packs lists the loaded packs" do
      hermetic
      h, _graph, _rt = handler
      h._handle_packs
      body = JSON.parse(h.response_body.not_nil!)
      body["total"].as_i.should be >= 1
      names = body["packs"].as_a.map { |p| p["name"].as_s }
      names.should contain("core")
    end

    it "GET /frames lists tracked frames" do
      hermetic
      h, _graph, _rt = handler
      h._handle_frames
      body = JSON.parse(h.response_body.not_nil!)
      body["total"].as_i.should eq(0)
    end
  end

  describe "chat endpoint" do
    it "POST /chat runs the chat pipeline and returns a reply" do
      hermetic
      h, _graph, _rt = handler
      h._handle_chat(body({"content" => "Hello there"}))
      h.response_status.should eq(200)
      body = JSON.parse(h.response_body.not_nil!)
      body["user_message"].as_s.should eq("Hello there")
      body["content"].as_s.should_not be_empty
      body["frame_id"].as_s.should_not be_empty
      body["llm_mode"].as_s.should eq("mock")
    end

    it "rejects empty chat content" do
      hermetic
      h, _graph, _rt = handler
      h._handle_chat(body({"content" => "   "}))
      h.response_status.should eq(400)
    end
  end

  describe "chat/config + secrets endpoints" do
    it "GET /chat/config reports the mock mode and supported providers" do
      hermetic
      h, _graph, _rt = handler
      h._handle_chat_config_get
      body = JSON.parse(h.response_body.not_nil!)
      body["mode"].as_s.should eq("mock")
      providers = body["providers"].as_a
      providers.map { |p| p["id"].as_s }.should contain("anthropic")
    end

    it "POST /chat/config rejects an unsupported provider" do
      hermetic
      h, _graph, _rt = handler
      h._handle_chat_config_post(body({"provider" => "notreal"}))
      h.response_status.should eq(400)
    end

    it "GET /secrets lists name-only credential refs" do
      hermetic
      h, _graph, _rt = handler
      h._handle_secrets_get
      body = JSON.parse(h.response_body.not_nil!)
      body["credentials"].as_a.should eq([] of JSON::Any)
      body["total"].as_i.should eq(0)
    end

    it "POST /secrets registers a name-only ref and never echoes the value" do
      hermetic
      h, _graph, _rt = handler
      h._handle_secrets_post(body({"name" => "DEMO_KEY", "value" => "sk-1234"}))
      h.response_status.should eq(200)
      body = JSON.parse(h.response_body.not_nil!)
      names = body["credentials"].as_a.map { |c| c["name"].as_s }
      names.should contain("DEMO_KEY")
      h.response_body.not_nil!.should_not contain("sk-1234")
    end

    it "POST /secrets refuses reserved system variables" do
      hermetic
      h, _graph, _rt = handler
      h._handle_secrets_post(body({"name" => "PATH", "value" => "/evil"}))
      h.response_status.should eq(400)
    end
  end

  describe "sessions endpoint" do
    it "GET /sessions lists chat sessions" do
      hermetic
      h, _graph, rt = handler
      rt.graph.not_nil!.add_object("chat_session", %({"user_ref":"alice","status":"active","turn_count":0,"started_at":"2026-01-01T00:00:00Z"}))
      h._handle_sessions_get
      body = JSON.parse(h.response_body.not_nil!)
      body["count"].as_i.should eq(1)
      body["sessions"].as_a.first["user_ref"].as_s.should eq("alice")
    end
  end

  describe "approvals endpoints" do
    it "GET /approvals returns pending + recent decisions (JSON)" do
      hermetic
      h, _graph, _rt = handler
      h._handle_approvals_get
      h.response_status.should eq(200)
      body = JSON.parse(h.response_body.not_nil!)
      body["pending"].should be_a(JSON::Any)
      body["recent_approvals"].as_a.should eq([] of JSON::Any)
      body["recent_denials"].as_a.should eq([] of JSON::Any)
    end

    it "POST /approvals refuses without channel auth when a token is required" do
      hermetic
      h, _graph, _rt = handler
      Chronicle::Packs::DemoServer._set_approval_token("tok")
      begin
        h._handle_approvals_post(body({"call_id" => "x", "decision" => "approve"}))
        h.response_status.should eq(401)
      ensure
        Chronicle::Packs::DemoServer._clear_approval_token
      end
    end
  end

  describe "health + reset + dispatch routing" do
    it "_dispatch_get routes /health to ok" do
      hermetic
      h, _graph, _rt = handler
      h._dispatch_get("/health", {} of String => String)
      h.response_status.should eq(200)
      JSON.parse(h.response_body.not_nil!)["status"].as_s.should eq("ok")
    end

    it "_dispatch_get 404s unknown paths" do
      hermetic
      h, _graph, _rt = handler
      h._dispatch_get("/nope", {} of String => String)
      h.response_status.should eq(404)
    end

    it "POST /reset re-seeds the runtime" do
      hermetic
      h, _graph, _rt = handler
      h._dispatch_post("/reset", {} of String => JSON::Any)
      h.response_status.should eq(200)
      body = JSON.parse(h.response_body.not_nil!)
      body["success"].as_bool.should be_true
    end
  end
end

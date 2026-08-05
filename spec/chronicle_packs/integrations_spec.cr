require "spec"
require "../spec_helper"

# Provider-neutral integration profiles and explorer receipts — the
# reusable connector chassis: understanding keyed to (service, account)
# that survives route changes.

module IntegrationSupport
  extend self

  def with_gateway_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    yield store, graph, rt
  end
end

include IntegrationSupport

describe "integration profiles" do
  it "derives stable integration ids" do
    tg = Chronicle::Packs::ToolGateway
    a = tg.stable_integration_id("integration", "gmail", "user_1")
    b = tg.stable_integration_id("integration", "gmail", "user_1")
    a.should eq(b)
    a.should start_with("integration_")
    tg.stable_integration_id("integration", "gmail", "user_2").should_not eq(a)
  end

  it "fingerprints shape, not content" do
    tg = Chronicle::Packs::ToolGateway
    left = JSON.parse(%({"a": 1, "b": [{"x": "hello", "y": 2}]}))
    right = JSON.parse(%({"b": [{"x": "world", "y": 3}], "a": 9}))
    tg.shape_fingerprint(left).should eq(tg.shape_fingerprint(right))
    tg.shape_fingerprint(left).should start_with("sha256:")
    tg.shape_fingerprint(JSON.parse(%({"a": {"nested": true}}))).should_not eq(tg.shape_fingerprint(left))
  end

  it "produces a sanitizer-safe fingerprint" do
    tg = Chronicle::Packs::ToolGateway
    fp = tg.safe_sha256_fingerprint("tok_secret_value")
    fp.should start_with("sha256:")
    fp.split(".").size.should eq(8)
    tg.safe_sha256_fingerprint("tok_secret_value").should eq(fp)
  end

  it "ensures an aggregator profile idempotently" do
    with_gateway_runtime do |_store, graph, _rt|
      tg = Chronicle::Packs::ToolGateway
      first = tg.ensure_aggregator_profile_fn(graph, aggregator: "composio", user_ref: "u_1", auth_state: "connected", enabled_services: ["gmail"])
      JSON.parse(first.data)["aggregator"].as_s.should eq("composio")
      second = tg.ensure_aggregator_profile_fn(graph, aggregator: "composio", user_ref: "u_1", auth_state: "connected", enabled_services: ["gmail"])
      second.id.should eq(first.id)
      graph.objects(type: "aggregator_profile").size.should eq(1)
    end
  end

  it "records versioned integration profiles, superseding on semantic change" do
    with_gateway_runtime do |_store, graph, _rt|
      tg = Chronicle::Packs::ToolGateway
      v1, created1 = tg.record_integration_profile_fn(graph, service: "gmail", account_ref: "u_1", routes: [{"path" => JSON::Any.new("imap"), "route_ref" => JSON::Any.new("r1")}], scopes_granted: ["read"])
      created1.should be_true
      JSON.parse(v1.data)["profile_version"].as_i.should eq(1)

      again, changed = tg.record_integration_profile_fn(graph, service: "gmail", account_ref: "u_1", routes: [{"path" => JSON::Any.new("imap"), "route_ref" => JSON::Any.new("r1")}], scopes_granted: ["read"])
      changed.should be_false
      again.id.should eq(v1.id)

      v2, created2 = tg.record_integration_profile_fn(graph, service: "gmail", account_ref: "u_1", routes: [{"path" => JSON::Any.new("imap"), "route_ref" => JSON::Any.new("r1")}], scopes_granted: ["read", "write"])
      created2.should be_true
      JSON.parse(v2.data)["profile_version"].as_i.should eq(2)
      graph.objects(type: "integration_profile").size.should eq(2)
      graph.relations.any? { |rel| rel.type == "integration_supersedes" }.should be_true

      latest = tg.latest_integration_profile(graph, "gmail", "u_1")
      latest.not_nil!.id.should eq(v2.id)
      active = tg.active_integration_profile(graph, "gmail", "u_1")
      active.not_nil!.id.should eq(v2.id)
    end
  end

  it "corrects a machine claim with a recorded operator claim" do
    with_gateway_runtime do |_store, graph, _rt|
      tg = Chronicle::Packs::ToolGateway
      profile, _ = tg.record_integration_profile_fn(graph, service: "gmail", account_ref: "u_1", routes: [] of Hash(String, JSON::Any), claims: [{"claim_key" => JSON::Any.new("owner"), "value" => JSON::Any.new("machine-guessed"), "confidence" => JSON::Any.new(0.3), "asserted_by" => JSON::Any.new("scanner")}])
      profile_id = profile.id

      corrected = tg.correct_integration_claim_fn(graph, profile_id: profile_id, claim_key: "owner", value: JSON::Any.new("operator-said"), actor: "operator", reason: "manual review")
      corrected["created"].as_bool.should be_true
      new_profile = graph.get_object(corrected["profile_id"].as_s)
      claims = JSON.parse(new_profile.not_nil!.data)["claims"].as_a
      claims.size.should eq(1)
      claim = claims.first.as_h
      claim["value"].as_s.should eq("operator-said")
      claim["classification_source"].as_s.should eq("operator")
      claim["confidence"].as_f.should eq(1.0)
      claim["metadata"].as_h["reason"].as_s.should eq("manual review")
    end
  end

  it "records budgeted exploration receipts with shape fingerprints" do
    with_gateway_runtime do |_store, graph, _rt|
      tg = Chronicle::Packs::ToolGateway
      profile, _ = tg.record_integration_profile_fn(graph, service: "gmail", account_ref: "u_1", routes: [] of Hash(String, JSON::Any))
      receipt, created = tg.record_exploration_fn(graph, service: "gmail", account_ref: "u_1", route: "imap", probe_call_ids: ["c1", "c2"], budget: 50, status: "completed", observed_shape: JSON.parse(%({"kind": "object"})), profile_id: profile.id)
      created.should be_true
      JSON.parse(receipt.data)["shape_fingerprint"].as_s.should start_with("sha256:")
      graph.relations.any? { |rel| rel.type == "profile_explored_by" }.should be_true

      again, changed = tg.record_exploration_fn(graph, service: "gmail", account_ref: "u_1", route: "imap", probe_call_ids: ["c1", "c2"], budget: 50, status: "completed")
      changed.should be_false
      again.id.should eq(receipt.id)
    end
  end
end

require "spec"
require "digest"
require "../spec_helper"

# Connector Control pack (packs/connector_control): neutral connector
# control-plane materializations. Ported red-green from upstream
# revision 6639a5385518ad49f74813373c85cf96eff9adc0.

module ConnectorControlSpecSupport
  extend self

  def with_control_runtime(settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::ConnectorControl.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::ConnectorControl.pack).should be_true
    end
    yield store, graph, rt
  end

  def record_binding(graph, source_surface_id : String = "chat/s1", service : String = "gmail", account_ref : String = "acc_1", family : String = "conversation", active_route : String = "native", routes : Array(String)? = nil, manual_refresh : Bool = false, status : String = "active")
    Chronicle::Packs::ConnectorControl.record_connector_binding_fn(
      graph, source_surface_id: source_surface_id, service: service, account_ref: account_ref,
      family: family, active_route: active_route, domain_run_type: "connector_run",
      routes: routes, manual_refresh_available: manual_refresh, status: status,
    )
  end
end

include ConnectorControlSpecSupport

describe Chronicle::Packs::ConnectorControl do
  describe "surface" do
    it "declares the object types, behaviors, tools, and settings schema" do
      pack = Chronicle::Packs::ConnectorControl.pack
      pack.object_types.map(&.name).should contain("connector_surface_binding")
      pack.object_types.map(&.name).should contain("connector_learning_delta")
      pack.behaviors.map(&.name).should contain("seed_connector_operational_policy")
      pack.behaviors.map(&.name).should contain("project_source_lifecycle_to_connector_binding")
      pack.tools.map(&.name).should contain("record_connector_binding")
      pack.tools.map(&.name).should contain("request_connector_refresh")
      pack.settings_schema.should eq("ConnectorControlSettings")
    end
  end

  describe "record_connector_binding_fn" do
    it "creates a binding and accumulates routes on refresh" do
      with_control_runtime do |_store, graph, _rt|
        first = record_binding(graph, routes: ["export"])
        first["created"].as_bool.should be_true

        second = record_binding(graph, routes: ["mcp"])
        second["created"].as_bool.should be_false
        bindings = graph.objects(type: "connector_surface_binding")
        bindings.size.should eq(1)
        routes = JSON.parse(bindings.first.data)["routes"].as_a.map(&.as_s)
        routes.should contain("export")
        routes.should contain("mcp")
        routes.should contain("native")
      end
    end

    it "updates non-immutable fields on refresh" do
      with_control_runtime do |_store, graph, _rt|
        record_binding(graph, source_surface_id: "s_imm", service: "gmail", active_route: "native")
        record_binding(graph, source_surface_id: "s_imm", service: "gmail", active_route: "mcp")
        bindings = graph.objects(type: "connector_surface_binding")
        bindings.size.should eq(1)
        JSON.parse(bindings.first.data)["active_route"].as_s.should eq("mcp")
        JSON.parse(bindings.first.data)["routes"].as_a.map(&.as_s).should contain("native")
      end
    end
  end

  describe "record_connector_run_observation_fn" do
    it "derives health and appends terminal event ids across states" do
      with_control_runtime do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        cc.record_connector_run_observation_fn(graph, domain_run_id: "run_1", source_surface_id: "chat/s1", service: "gmail", account_ref: "acc_1", family: "conversation", route: "native", state: "running", phase: "running", mode: "manual", source_event_id: "ev_1")
        cc.record_connector_run_observation_fn(graph, domain_run_id: "run_1", source_surface_id: "chat/s1", service: "gmail", account_ref: "acc_1", family: "conversation", route: "native", state: "succeeded", phase: "done", mode: "manual", source_event_id: "ev_2")

        obs = graph.objects(type: "connector_run_observation").first
        data = JSON.parse(obs.data)
        data["health"].as_s.should eq("current")
        data["terminal_event_ids"].as_a.map(&.as_s).should contain("ev_2")
        data["update_event_ids"].as_a.map(&.as_s).should contain("ev_1")
      end
    end
  end

  describe "record_connector_learning_delta_fn" do
    it "caps refs and exceptions by settings" do
      settings = Chronicle::Packs::ConnectorControl::ConnectorControlSettings.from_json(%({"max_refs_per_delta":2,"max_exceptions_per_delta":1}))
      with_control_runtime(settings) do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        cc.record_connector_learning_delta_fn(graph, domain_run_id: "run_2", source_surface_id: "chat/s1", service: "gmail", family: "conversation", refs: ["a", "b", "c", "d"], exceptions: [{"m" => JSON::Any.new("x")}, {"m" => JSON::Any.new("y")}], settings: settings)
        delta = graph.objects(type: "connector_learning_delta").first
        data = JSON.parse(delta.data)
        data["refs"].as_a.size.should eq(2)
        data["exceptions"].as_a.size.should eq(1)
      end
    end
  end

  describe "validate_native_data and record_connector_native_view_fn" do
    it "validates a conversation native payload and rejects unknown families" do
      with_control_runtime do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        data = JSON.parse(%({"threads":[{"thread_ref":"t1","title":"Hello"}],"total_count":1})).as_h
        result = cc.record_connector_native_view_fn(graph, source_surface_id: "chat/s1", service: "gmail", family: "conversation", state: "ready", data: data)
        result["created"].as_bool.should be_true
        expect_raises(Exception) do
          cc.validate_native_data("unknown_family", data)
        end
      end
    end

    it "accepts each of the five closed native family shapes" do
      with_control_runtime do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        {
          "conversation" => %({"threads":[],"total_count":0}),
          "schedule"     => %({"occurrences":[],"total_count":0}),
          "records"      => %({"columns":[],"rows":[],"total_count":0}),
          "documents"    => %({"items":[],"total_count":0}),
          "telemetry"    => %({"points":[],"unit":"count"}),
        }.each do |family, json|
          result = cc.record_connector_native_view_fn(graph,
            source_surface_id: "fixture:#{family}", service: "fixture",
            family: family, state: "empty", data: JSON.parse(json).as_h)
          data = JSON.parse(graph.get_object(result["view"].as_s).not_nil!.data)
          data["family"].as_s.should eq(family)
          data["state"].as_s.should eq("empty")
        end
      end
    end

    it "rejects provider-shaped fields outside the native family contract" do
      with_control_runtime do |_store, graph, _rt|
        expect_raises(ArgumentError, /unknown conversation native data field/) do
          Chronicle::Packs::ConnectorControl.record_connector_native_view_fn(graph,
            source_surface_id: "mail:owner", service: "gmail",
            family: "conversation", state: "ready",
            data: JSON.parse(%({"messages":[{"gmailMessageId":"provider-leak"}]})).as_h)
        end
      end
    end
  end

  describe "projections" do
    it "projects bindings, runs, and native views" do
      with_control_runtime do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        record_binding(graph, source_surface_id: "chat/s1")
        cc.record_connector_run_observation_fn(graph, domain_run_id: "run_3", source_surface_id: "chat/s1", service: "gmail", account_ref: "acc_1", family: "conversation", route: "native", state: "queued", phase: "queued", mode: "manual")
        cc.record_connector_native_view_fn(graph, source_surface_id: "chat/s1", service: "gmail", family: "conversation", state: "empty", data: {} of String => JSON::Any)

        plane = cc.project_connector_control_plane_fn(graph)
        plane["bindings"].as_a.size.should eq(1)
        plane["runs"].as_a.size.should eq(1)
        plane["native_views"].as_a.size.should eq(1)
      end
    end

    it "projects learning deltas" do
      with_control_runtime do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        cc.record_connector_learning_delta_fn(graph, domain_run_id: "run_4", source_surface_id: "chat/s1", service: "gmail", family: "conversation")
        deltas = cc.project_connector_learning_deltas_fn(graph)
        deltas["deltas"].as_a.size.should eq(1)
      end
    end
  end

  describe "request_connector_refresh_fn" do
    it "fails without a single active binding" do
      with_control_runtime do |_store, graph, _rt|
        expect_raises(Exception) do
          Chronicle::Packs::ConnectorControl.request_connector_refresh_fn(graph, "missing_surface")
        end
      end
    end

    it "records a failed request when no service handler is registered" do
      with_control_runtime do |_store, graph, _rt|
        record_binding(graph, source_surface_id: "chat/refresh", manual_refresh: true)
        result = Chronicle::Packs::ConnectorControl.request_connector_refresh_fn(graph, "chat/refresh")
        result["ok"].as_bool.should be_false
        result["error"].as_s.should eq("maintenance_handler_unavailable")
        request = graph.objects(type: "connector_maintenance_request").first
        JSON.parse(request.data)["status"].as_s.should eq("failed")
      end
    end

    it "accepts when a service handler is registered" do
      with_control_runtime do |_store, graph, _rt|
        cc = Chronicle::Packs::ConnectorControl
        record_binding(graph, source_surface_id: "chat/handler", manual_refresh: true)
        cc.register_connector_maintenance_handler("gmail", ->(_g : Chronicle::GraphProjection, _b : Chronicle::GraphObject, _r : Chronicle::GraphObject) { {"run_id" => JSON::Any.new("maintenance_run_1")} })
        result = cc.request_connector_refresh_fn(graph, "chat/handler")
        result["ok"].as_bool.should be_true
        result["domain_run_id"].as_s.should eq("maintenance_run_1")
        request = graph.objects(type: "connector_maintenance_request").first
        JSON.parse(request.data)["status"].as_s.should eq("accepted")
      ensure
        Chronicle::Packs::ConnectorControl.clear_connector_maintenance_handlers
      end
    end

    it "fails closed when the binding has been revoked" do
      with_control_runtime do |_store, graph, _rt|
        record_binding(graph, source_surface_id: "mail/revoked", manual_refresh: true, status: "revoked")
        expect_raises(Chronicle::Packs::PackError, /reconnect before refreshing/) do
          Chronicle::Packs::ConnectorControl.request_connector_refresh_fn(graph, "mail/revoked")
        end
      end
    end
  end

  describe "behaviors" do
    it "seeds the operational policy once on pack load" do
      with_control_runtime do |_store, graph, rt|
        rt.run_until_idle
        policies = graph.objects(type: "connector_operational_policy")
        policies.size.should eq(1)
        JSON.parse(policies.first.data)["policy_identity"].as_s.should eq("connector-operational@0.1.0")
        rt.run_until_idle
        graph.objects(type: "connector_operational_policy").size.should eq(1)
      end
    end

    it "projects source lifecycle into binding status" do
      with_control_runtime do |_store, graph, rt|
        record_binding(graph, source_surface_id: "chat/lifecycle")
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 1_u64, id: "lifecycle_1", type: "source.lifecycle_changed",
          actor: "system", caused_by: nil,
          payload: %({"surface_id":"chat/lifecycle","status":"failed"}),
        ))
        rt.run_until_idle
        binding = graph.objects(type: "connector_surface_binding").first
        JSON.parse(binding.data)["status"].as_s.should eq("stale")
      end
    end
  end

  describe "operational" do
    it "builds the default policy payload" do
      payload = Chronicle::Packs::ConnectorControl.operational_policy_payload
      payload["policy_identity"].as_s.should eq("connector-operational@0.1.0")
      payload["fixture_items"].as_i.should eq(250)
    end

    it "flags budget violations against the policy" do
      cc = Chronicle::Packs::ConnectorControl
      measurement = Chronicle::Packs::ConnectorControl::ConnectorOperationalMeasurement.new(
        domain_run_id: "run_m", evidence_items: 500, durable_events: 0, events_per_evidence: 0.0,
        annotations: 0, max_annotations_for_one_evidence: 0, behavior_firings: 0,
        behavior_firings_per_evidence: 0.0, provider_calls: 0, artifact_bytes: 0,
      )
      violations = cc.operational_budget_violations(measurement)
      violations.should contain("evidence_items: 500 > 250")
    end
  end
end

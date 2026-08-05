require "spec"
require "digest"
require "../spec_helper"

# Usage pack (packs/usage): neutral connection, coverage, settlement, and
# activity fact schemas. Ported red-green from upstream
# revision 6639a5385518ad49f74813373c85cf96eff9adc0.

module UsageSpecSupport
  extend self

  def with_usage_runtime(settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::Usage.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::Usage.pack).should be_true
    end
    yield store, graph, rt
  end

  def connect(graph, surface_id : String = "chat/sess_1", category : String = "communication", path : String = "export", acquisition_mode : String = "snapshot", settings = Chronicle::Packs::Usage::UsageSettings.new)
    Chronicle::Packs::Usage.connect_surface_fn(graph, surface_id, category, path: path, acquisition_mode: acquisition_mode, settings: settings)
  end

  def ingest(graph, surface_id : String = "chat/sess_1", evidence_identity : String = "ev_1", source_ref : String = "msg_1", provider_time : String = "2026-07-01T00:00:00Z")
    Chronicle::Packs::Usage.record_usage_fn(
      graph, "usage_#{evidence_identity}", surface_id, "interaction",
      evidence_identity: evidence_identity, provider_time: provider_time,
    )
  end
end

include UsageSpecSupport

describe Chronicle::Packs::Usage do
  describe "surface" do
    it "declares object types, relation types, behaviors, tools, and settings" do
      pack = Chronicle::Packs::Usage.pack
      pack.object_types.map(&.name).should contain("connection_surface")
      pack.object_types.map(&.name).should contain("usage_evidence")
      pack.relation_types.map(&.name).should contain("evidence_on_surface")
      pack.behaviors.map(&.name).should contain("observe_normalized_evidence")
      pack.tools.map(&.name).should contain("connect_source_surface")
      pack.tools.map(&.name).should contain("query_usage")
      pack.settings_schema.should eq("UsageSettings")
    end
  end

  describe "connect_surface_fn" do
    it "creates a surface and ensures the default settling gate" do
      with_usage_runtime do |_store, graph, _rt|
        result = connect(graph)
        result["created"].as_bool.should be_true
        graph.objects(type: "connection_surface").size.should eq(1)
        graph.objects(type: "settling_gate").size.should eq(1)
        gate = graph.objects(type: "settling_gate").first
        JSON.parse(gate.data)["gate_id"].as_s.should eq("usage.category.default")
        graph.events.any? { |e| e.type == "source.connected" }.should be_true
      end
    end

    it "reconnects without duplicating and rejects immutable changes" do
      with_usage_runtime do |_store, graph, _rt|
        connect(graph)
        result = connect(graph)
        result["created"].as_bool.should be_false
        graph.objects(type: "connection_surface").size.should eq(1)
        expect_raises(Exception) do
          connect(graph, category: "rhythm")
        end
      end
    end
  end

  describe "record_usage_fn" do
    it "records an idempotent interaction fact and rejects divergent facts" do
      with_usage_runtime do |_store, graph, _rt|
        connect(graph)
        result = ingest(graph)
        result["created"].as_bool.should be_true
        graph.objects(type: "usage_record").size.should eq(1)
        graph.relations(type: "usage_on_surface").size.should eq(1)
        graph.events.any? { |e| e.type == "usage.recorded" }.should be_true

        replay = ingest(graph)
        replay["created"].as_bool.should be_false

        expect_raises(Exception) do
          Chronicle::Packs::Usage.record_usage_fn(graph, "usage_ev_1", "chat/sess_1", "interaction", count: 5)
        end
      end
    end
  end

  describe "record_source_clock_fn" do
    it "records idempotent clock inputs only for live surfaces" do
      with_usage_runtime do |_store, graph, _rt|
        connect(graph, acquisition_mode: "live", path: "mcp")
        result = Chronicle::Packs::Usage.record_source_clock_fn(graph, "chat/sess_1", "2026-07-01T00:00:00Z")
        result["created"].as_bool.should be_true
        replay = Chronicle::Packs::Usage.record_source_clock_fn(graph, "chat/sess_1", "2026-07-01T00:00:00Z")
        replay["created"].as_bool.should be_false

        expect_raises(Exception) do
          Chronicle::Packs::Usage.record_source_clock_fn(graph, "chat/sess_1", "not-a-timestamp")
        end
      end
    end
  end

  describe "set_surface_status_fn" do
    it "records explicit lifecycle facts" do
      with_usage_runtime do |_store, graph, _rt|
        connect(graph)
        result = Chronicle::Packs::Usage.set_surface_status_fn(graph, "chat/sess_1", "revoked", reason: "owner removed")
        result["status"].as_s.should eq("revoked")
        surface = graph.objects(type: "connection_surface").first
        JSON.parse(surface.data)["status"].as_s.should eq("revoked")
        graph.events.any? { |e| e.type == "source.lifecycle_changed" }.should be_true
        expect_raises(Exception) do
          Chronicle::Packs::Usage.set_surface_status_fn(graph, "chat/sess_1", "settled")
        end
      end
    end
  end

  describe "behaviors" do
    it "fulfills source_connection_request into a canonical surface" do
      with_usage_runtime do |_store, graph, rt|
        graph.add_object("source_connection_request", JSON.build do |json|
          json.object do
            json.field "request_identity", "req_1"
            json.field "surface_id", "gmail/acc_2"
            json.field "category", "communication"
            json.field "provider", {} of String => JSON::Any
            json.field "path", "export"
            json.field "privacy_scope", "account"
            json.field "status", "proposed"
          end
        end)
        rt.run_until_idle

        request = graph.objects(type: "source_connection_request").first
        request_data = JSON.parse(request.data)
        request_data["status"].as_s.should eq("fulfilled")
        graph.objects(type: "connection_surface").size.should eq(1)
      end
    end

    it "indexes normalized evidence and evaluates the surface gate" do
      gate_settings = Chronicle::Packs::Usage::UsageSettings.from_json(%({"default_gate_id":"usage.custom","default_gate_version":1,"min_unique_events":1}))
      with_usage_runtime(gate_settings) do |_store, graph, rt|
        connect(graph, settings: gate_settings)
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 1_u64, id: "ingest_1", type: "source.event_ingested",
          actor: "activity_normalizer", caused_by: nil,
          payload: %({"source_surface_id":"chat/sess_1","evidence_identity":"ev_1","evidence_id":"evidence_1","revision_id":"rev_1","revision_number":1,"source_ref":"msg_1","source_category":"communication","connection_path":"export","provider_time":"2026-07-01T00:00:00Z","importer_id":"chatgpt_export","importer_version":"1.0.0","is_fixture":false,"invalidated":false,"replay_complete":false}),
        ))
        rt.run_until_idle

        evidence = graph.objects(type: "usage_evidence")
        evidence.size.should eq(1)
        surface = graph.objects(type: "connection_surface").first
        JSON.parse(surface.data)["status"].as_s.should eq("settled")
        JSON.parse(surface.data)["settled_by"].as_a.map(&.as_s).should contain("volume")
        graph.objects(type: "settlement_record").size.should eq(1)
      end
    end

    it "projects cursor progress and invalidates evidence" do
      with_usage_runtime do |_store, graph, rt|
        connect(graph)
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 1_u64, id: "cursor_1", type: "source.cursor_advanced",
          actor: "activity_normalizer", caused_by: nil,
          payload: %({"source_surface_id":"chat/sess_1","oldest_ingested_ref":"10","newest_ingested_ref":"20","watermark_ref":"42","cursor_version":2}),
        ))
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 2_u64, id: "invalid_1", type: "source.evidence_invalidated",
          actor: "activity_normalizer", caused_by: nil,
          payload: %({"source_surface_id":"chat/sess_1","evidence_identity":"ev_x","reason":"provider_deleted"}),
        ))
        rt.run_until_idle

        surface = graph.objects(type: "connection_surface").first
        cursor = JSON.parse(surface.data)["cursor_state"].as_h
        cursor["newest_ingested_ref"].as_s.should eq("20")
        cursor["cursor_version"].as_i.should eq(2)
        graph.events.any? { |e| e.type == "source.cursor_advanced" }.should be_true
      end
    end
  end

  describe "project_usage_fn" do
    it "replays the log through a horizon into deterministic surface state" do
      with_usage_runtime do |_store, graph, rt|
        connect(graph, surface_id: "chat/proj")
        result = Chronicle::Packs::Usage.record_usage_fn(graph, "usage_proj_1", "chat/proj", "interaction", provider_time: "2026-07-01T00:00:00Z")
        event_id = result["event_id"].as_s

        projected = Chronicle::Packs::Usage.project_usage_fn(graph, event_id)
        projected["surfaces"].as_a.size.should eq(1)
        row = projected["surfaces"].as_a.first.as_h
        row["status"].as_s.should eq("connected")
        usage = projected["usage"].as_h
        usage["total"].as_i.should eq(1)
      end
    end
  end
end

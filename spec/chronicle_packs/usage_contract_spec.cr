require "spec"
require "../spec_helper"

# P2 acceptance contract for neutral, explicit-horizon usage projections
# (upstream tests/test_usage.py). Connections never settle on their own;
# the default gate passes by volume OR provider-time coverage; reconnect and
# reimport never duplicate the settled tuple; stale/revoked statuses are
# horizon-deterministic and log-replayable; fixture evidence is visible but
# excluded from gate totals; the pack surface uses neutral vocabulary.

module UsageContractSpecSupport
  extend self

  def with_usage_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::Usage.pack).should be_true
    yield store, graph, rt
  end

  def emit_evidence(graph, surface_id : String, identity : String, *, category : String, path : String, provider_time : String? = "2024-01-01T00:00:00+00:00", is_fixture : Bool = false, revision_number : Int32 = 1)
    event = Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: (graph.events.size + 1).to_u64,
      id: graph.ids.event,
      type: "source.event_ingested",
      actor: "usage.acceptance",
      caused_by: nil,
      payload: JSON.build do |json|
        json.object do
          json.field "evidence_identity", identity
          json.field "evidence_id", "activity_evidence##{identity}"
          json.field "revision_id", "revision:#{identity}:#{revision_number}"
          json.field "revision_number", revision_number
          json.field "source_surface_id", surface_id
          json.field "provider_item_id", identity
          json.field "source_ref", "fixture://#{surface_id}/#{identity}"
          json.field "content_hash", "hash:#{identity}:#{revision_number}"
          json.field "provider_time", provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
          json.field "source_category", category
          json.field "connection_path", path
          json.field "importer_id", "usage_acceptance"
          json.field "importer_version", "0.1.0"
          json.field "is_fixture", is_fixture
          json.field "replay_complete", true
          json.field "invalidated", false
        end
      end,
    )
    graph.emit(event)
    event.id
  end

  def settled_events(graph, surface_id : String) : Array(Chronicle::Event)
    graph.events.select do |event|
      if event.type == "source.settled"
        payload = JSON.parse(event.payload).as_h
        payload["surface_id"]?.try(&.as_s?) == surface_id &&
          payload["gate_id"]?.try(&.as_s?) == "usage.category.default" &&
          payload["gate_version"]?.try(&.as_i?) == 1
      else
        false
      end
    end
  end

  def replay(events : Array(Chronicle::Event), graph : Chronicle::GraphProjection) : Chronicle::GraphProjection
    replayed = Chronicle::GraphProjection.empty
    events.each { |event| replayed.apply(event) }
    replayed.ids.reseed_from_events(events)
    replayed
  end
end

include UsageContractSpecSupport

describe "usage P2 acceptance contract" do
  it "a connection alone never settles or contributes" do
    with_usage_runtime do |_store, graph, _rt|
      result = Chronicle::Packs::Usage.connect_surface_fn(
        graph, "surface_connection_only", "communication",
        provider: {"name" => JSON::Any.new("Example")}, path: "native", acquisition_mode: "live",
      )
      horizon = result["connection_event_id"].as_s

      settlement = Chronicle::Packs::Usage.get_settlement_fn(graph, horizon, "surface_connection_only")
      settlement["status"].as_s.should eq("connected")
      settlement["passed"].as_bool.should be_false
      settlement["settled_event_id"]?.try(&.raw).should be_nil
      settled_events(graph, "surface_connection_only").should be_empty
    end
  end

  it "the default gate passes by volume or provider-time coverage" do
    with_usage_runtime do |_store, graph, _rt|
      Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_volume", "local_knowledge", path: "local")
      Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_coverage", "ai_activity", path: "export")
      25.times do |index|
        emit_evidence(graph, "surface_volume", "volume-%02d" % index, category: "local_knowledge", path: "local")
      end
      emit_evidence(graph, "surface_coverage", "coverage-start", category: "ai_activity", path: "export", provider_time: "2024-01-01T12:00:00+00:00")
      emit_evidence(graph, "surface_coverage", "coverage-end", category: "ai_activity", path: "export", provider_time: "2024-01-04T12:00:00+00:00")

      horizon = graph.events.last.id
      volume = Chronicle::Packs::Usage.get_settlement_fn(graph, horizon, "surface_volume")
      coverage = Chronicle::Packs::Usage.get_settlement_fn(graph, horizon, "surface_coverage")
      volume["status"].as_s.should eq("settled")
      volume["passed_by"].as_s.should eq("volume")
      coverage["status"].as_s.should eq("settled")
      coverage["passed_by"].as_s.should eq("coverage")

      stats = Chronicle::Packs::Usage.get_coverage_fn(graph, horizon)["by_surface"].as_h
      stats["surface_volume"].as_h["unique_evidence"].as_i.should eq(25)
      stats["surface_coverage"].as_h["coverage_days"].as_i.should eq(3)
    end
  end

  it "reconnect and reimport never duplicate the settled tuple" do
    with_usage_runtime do |_store, graph, rt|
      Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_retry", "local_knowledge", path: "local")
      25.times do |index|
        emit_evidence(graph, "surface_retry", "retry-%02d" % index, category: "local_knowledge", path: "local")
      end
      rt.run_until_idle
      settled_events(graph, "surface_retry").size.should eq(1)

      reconnect = Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_retry", "local_knowledge", path: "local")
      reconnect["created"].as_bool.should be_false
      25.times do |index|
        emit_evidence(graph, "surface_retry", "retry-%02d" % index, category: "local_knowledge", path: "local")
      end
      rt.run_until_idle
      horizon = graph.events.last.id

      settled_events(graph, "surface_retry").size.should eq(1)
      records = graph.objects(type: "settlement_record").select do |obj|
        data = JSON.parse(obj.data).as_h
        data["source_surface_id"]?.try(&.as_s?) == "surface_retry" &&
          data["gate_id"]?.try(&.as_s?) == "usage.category.default" &&
          data["gate_version"]?.try(&.as_i?) == 1
      end
      records.size.should eq(1)
      Chronicle::Packs::Usage.get_settlement_fn(graph, horizon, "surface_retry")["status"].as_s.should eq("settled")
    end
  end

  it "stale and revoked are horizon-deterministic and log-replayable" do
    with_usage_runtime do |_store, graph, _rt|
      Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_lifecycle", "ai_activity", path: "export")
      emit_evidence(graph, "surface_lifecycle", "life-start", category: "ai_activity", path: "export", provider_time: "2024-02-01T00:00:00+00:00")
      settled_horizon = emit_evidence(graph, "surface_lifecycle", "life-end", category: "ai_activity", path: "export", provider_time: "2024-02-04T00:00:00+00:00")
      stale_horizon = Chronicle::Packs::Usage.set_surface_status_fn(graph, "surface_lifecycle", "stale", reason: "source access expired")["event_id"].as_s
      revoked_horizon = Chronicle::Packs::Usage.set_surface_status_fn(graph, "surface_lifecycle", "revoked", reason: "owner revoked access")["event_id"].as_s

      expected = {
        settled_horizon => "settled",
        stale_horizon   => "stale",
        revoked_horizon => "revoked",
      }
      original_events = graph.events.dup
      replayed = replay(original_events, graph)

      expected.each do |horizon, status|
        original_projection = Chronicle::Packs::Usage.project_usage_fn(graph, horizon)
        replayed_projection = Chronicle::Packs::Usage.project_usage_fn(replayed, horizon)
        original_projection.should eq(replayed_projection)
        Chronicle::Packs::Usage.get_settlement_fn(graph, horizon, "surface_lifecycle")["status"].as_s.should eq(status)
      end
    end
  end

  it "rejects an unknown category loudly" do
    with_usage_runtime do |_store, graph, _rt|
      expect_raises(ArgumentError, /unknown source category/i) do
        Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_unknown", "other", path: "native")
      end
      graph.objects(type: "connection_surface").should be_empty
    end
  end

  it "fixture evidence is visible but excluded from gate totals" do
    with_usage_runtime do |_store, graph, _rt|
      Chronicle::Packs::Usage.connect_surface_fn(graph, "surface_fixture", "local_knowledge", path: "local")
      25.times do |index|
        emit_evidence(graph, "surface_fixture", "fixture-%02d" % index, category: "local_knowledge", path: "local", is_fixture: true)
      end
      horizon = graph.events.last.id

      settlement = Chronicle::Packs::Usage.get_settlement_fn(graph, horizon, "surface_fixture")
      stats = Chronicle::Packs::Usage.get_coverage_fn(graph, horizon)["by_surface"].as_h["surface_fixture"].as_h
      settlement["status"].as_s.should eq("connected")
      settlement["passed"].as_bool.should be_false
      stats["unique_evidence"].as_i.should eq(0)
      stats["fixture_evidence"].as_i.should eq(25)
      stats["visible_evidence_revisions"].as_i.should eq(25)
    end
  end

  it "the pack surface contains neutral facts and no game vocabulary" do
    forbidden = /(score|points?|badges?|levels?)/i
    pack = Chronicle::Packs::Usage.pack
    surfaces = [] of String
    surfaces << "#{pack.name} #{pack.description}"
    pack.object_types.each { |item| surfaces << "#{item.name} #{item.description}" }
    pack.relation_types.each { |item| surfaces << "#{item.name} #{item.description}" }
    pack.tools.each { |item| surfaces << item.name }
    violations = surfaces.select { |surface| forbidden.matches?(surface) }
    violations.should be_empty, "game vocabulary leaked into the usage surface: #{violations}"
  end
end

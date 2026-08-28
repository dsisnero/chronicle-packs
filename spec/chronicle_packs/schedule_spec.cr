require "spec"
require "../spec_helper"

# Schedule Pack (packs/schedule): graph-native scheduling. Translated from
# upstream packs/schedule/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). The clock lives at the edge —
# a host driver injects timestamps via emit_due_ticks; tick_router emits the
# schedule's payload, schedule_bookkeeper advances schedule state.

module ScheduleSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def schedule_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "schedule" / "manifest.toml"
  end

  # Mirrors upstream _runtime(): Core + Schedule, synthetic timestamps.
  def with_schedule_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::Schedule::ScheduleSettings.new
    rt.load_pack(Chronicle::Packs::Schedule.pack, JSON.parse(settings.to_json).as_h).should be_true
    yield store, graph, rt
  end
end

include ScheduleSpecSupport

T0          = "2026-07-08T09:00:00+00:00"
T0_PLUS_5M  = "2026-07-08T09:05:00+00:00"
T0_PLUS_10M = "2026-07-08T09:10:00+00:00"
NEXT_DAY    = "2026-07-09T09:30:00+00:00"

describe Chronicle::Packs::Schedule do
  describe "manifest-declared surface" do
    it "matches the upstream schedule manifest" do
      pack = Chronicle::Packs::Schedule.pack
      pack.name.should eq("schedule")
      pack.version.should eq("0.2.0")
      pack.object_types.map(&.name).should eq(
        ["schedule", "schedule_tick", "heartbeat"]
      )
      pack.relation_types.map(&.name).should eq(["tick_of", "emitted_by"])
      pack.behaviors.map(&.name).should eq(["tick_router", "schedule_bookkeeper"])
      pack.tools.map(&.name).should eq(
        ["create_schedule", "emit_due_ticks", "list_due_schedules", "set_schedule_enabled"]
      )
      pack.settings_schema.should eq("ScheduleSettings")
      pack.capabilities.map(&.capability).should eq(["create_reminder"])
      pack.capabilities.first.risk_class.should eq("low")
      pack.capabilities.first.action_class.should eq("R3")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(schedule_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Schedule.pack)
    end
  end

  describe "interval schedule" do
    it "fires when due, dedups re-fires, advances, and refires" do
      with_schedule_runtime do |_store, graph, rt|
        sched = Chronicle::Packs::Schedule.create_schedule_fn(
          graph, name: "pulse", kind: "interval", every_seconds: 300,
          payload_emit_type: "heartbeat", now: T0,
        )
        rt.run_until_idle

        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0).should eq([] of String)

        ticks = Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0_PLUS_5M)
        ticks.size.should eq(1)
        rt.run_until_idle

        beats = graph.objects(type: "heartbeat")
        beats.size.should eq(1)
        JSON.parse(beats.first.data)["sequence"].as_i.should eq(1)
        JSON.parse(beats.first.data)["metadata"]["schedule_id"].as_s.should eq(sched.id)

        updated = JSON.parse(graph.get_object(sched.id).not_nil!.data)
        updated["fire_count"].as_i.should eq(1)
        updated["last_fired_at"].as_s.starts_with?("2026-07-08T09:05").should be_true
        updated["next_due_at"].as_s.starts_with?("2026-07-08T09:10").should be_true

        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0_PLUS_5M).should eq([] of String)
        rt.run_until_idle
        graph.objects(type: "heartbeat").size.should eq(1)

        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0_PLUS_10M).size.should eq(1)
        rt.run_until_idle
        graph.objects(type: "heartbeat").size.should eq(2)

        rels = graph.relations.select { |r| r.type == "emitted_by" }
        rels.size.should eq(2)
        rels.all? { |r| r.to_id == sched.id }.should be_true
        graph.relations.select { |r| r.type == "tick_of" }.size.should eq(2)
      end
    end
  end

  describe "once schedule" do
    it "fires exactly once at its moment, then auto-disables" do
      with_schedule_runtime do |_store, graph, rt|
        sched = Chronicle::Packs::Schedule.create_schedule_fn(
          graph, name: "one-shot", kind: "once", at: T0_PLUS_5M,
          payload_emit_type: "task",
          payload_data: {"title" => JSON::Any.new("Prepare the board deck"), "status" => JSON::Any.new("active")},
          now: T0,
        )
        rt.run_until_idle

        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0_PLUS_5M).size.should eq(1)
        rt.run_until_idle

        tasks = graph.objects(type: "task").select do |t|
          JSON.parse(t.data)["title"]?.try(&.as_s?) == "Prepare the board deck"
        end
        tasks.size.should eq(1)
        JSON.parse(tasks.first.data)["metadata"]["schedule_id"].as_s.should eq(sched.id)

        after = JSON.parse(graph.get_object(sched.id).not_nil!.data)
        after["enabled"].as_bool.should be_false
        after["next_due_at"].raw.nil?.should be_true

        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, NEXT_DAY).should eq([] of String)
      end
    end
  end

  describe "daily schedule" do
    it "is due at HH:MM and advances a day after firing" do
      with_schedule_runtime do |_store, graph, rt|
        sched = Chronicle::Packs::Schedule.create_schedule_fn(
          graph, name: "morning brief", kind: "daily", at_time: "09:30",
          payload_emit_type: "heartbeat", now: T0,
        )
        rt.run_until_idle

        JSON.parse(graph.get_object(sched.id).not_nil!.data)["next_due_at"].as_s
          .starts_with?("2026-07-08T09:30").should be_true
        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0_PLUS_5M).should eq([] of String)
        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, "2026-07-08T09:31:00+00:00").size.should eq(1)
        rt.run_until_idle
        JSON.parse(graph.get_object(sched.id).not_nil!.data)["next_due_at"].as_s
          .starts_with?("2026-07-09T09:30").should be_true
      end
    end
  end

  describe "catch-up and disable" do
    it "fires missed schedules once and stays silent when disabled" do
      with_schedule_runtime do |_store, graph, rt|
        sched = Chronicle::Packs::Schedule.create_schedule_fn(
          graph, name: "pulse", kind: "interval", every_seconds: 300,
          payload_emit_type: "heartbeat", now: T0,
        )
        rt.run_until_idle

        ticks = Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, NEXT_DAY)
        ticks.size.should eq(1)
        rt.run_until_idle
        JSON.parse(graph.get_object(sched.id).not_nil!.data)["next_due_at"].as_s
          .starts_with?("2026-07-09T09:35").should be_true

        Chronicle::Packs::Schedule.set_schedule_enabled_fn(graph, sched.id, false)
        rt.run_until_idle
        Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, "2026-07-09T10:00:00+00:00").should eq([] of String)
        Chronicle::Packs::Schedule.list_due_fn(graph, "2026-07-09T10:00:00+00:00").should eq([] of Hash(String, JSON::Any))
      end
    end
  end

  describe "reminder payload" do
    it "emits an approved comm_response_candidate that gets dispatched" do
      store, graph, rt = PackSpecRuntime.runtime
      rt.load_pack(Chronicle::Packs::Core.pack).should be_true
      rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
      Chronicle::Packs::Communication.clear_thread_registry
      settings = Chronicle::Packs::Schedule::ScheduleSettings.new
      rt.load_pack(Chronicle::Packs::Schedule.pack, JSON.parse(settings.to_json).as_h).should be_true

      Chronicle::Packs::Schedule.create_schedule_fn(
        graph, name: "reminder: standup", kind: "once", at: T0_PLUS_5M,
        payload_emit_type: "comm_response_candidate",
        payload_data: {
          "message_id"          => JSON::Any.new(""),
          "channel"             => JSON::Any.new("chat"),
          "content"             => JSON::Any.new("Reminder: daily standup in 10 minutes."),
          "status"              => JSON::Any.new("approved"),
          "created_by_behavior" => JSON::Any.new("schedule.tick_router"),
          "metadata"            => JSON::Any.new({"reminder" => JSON::Any.new(true)}),
        },
        now: T0,
      )
      rt.run_until_idle
      Chronicle::Packs::Schedule.emit_due_ticks_fn(graph, T0_PLUS_5M)
      rt.run_until_idle

      cands = graph.objects(type: "comm_response_candidate")
      cands.size.should eq(1)
      data = JSON.parse(cands.first.data)
      data["status"].as_s.should eq("sent")
      data["metadata"]["reminder"].as_bool.should be_true
      data["metadata"]["schedule_id"].as_s.should_not be_empty
    ensure
      Chronicle::Packs::Communication.clear_thread_registry
    end
  end
end

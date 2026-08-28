require "json"
require "time"

module Chronicle::Packs::Schedule
  # Schedule Pack behaviors. Ported from upstream packs/schedule/behaviors.py.
  #
  # tick_router         — schedule_tick.created → emit the schedule's payload
  #                       (with metadata.schedule_id/tick_id/fired_at injected;
  #                       heartbeats get sequence stamped; unregistered payload
  #                       types are recorded as emit_skipped on the tick).
  # schedule_bookkeeper — schedule_tick.created → advance last_fired_at /
  #                       fire_count / next_due_at ('once' auto-disables).
  #
  # The tick IS the event; the graph owns schedule state. Catch-up policy:
  # next_due_at advances from the tick's fired_at (settings.catch_up='skip',
  # the only mode in v0.1) — missed periods are not replayed.

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json, actor: "schedule")
  end

  # Instantiate the due schedule's payload object. Runs before
  # schedule_bookkeeper (upstream BEHAVIORS declaration order): the payload
  # must be emitted while the schedule is still enabled.
  @[Chronicle::Packs::Annotations::Behavior(name: "tick_router", on: ["object.created"], where: {"type" => "schedule_tick"}, creates: [] of String, priority: 1)]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream tick_router payload/metadata branches
  def tick_router(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ScheduleSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    tick_id = payload["id"]?.try(&.as_s?)
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    schedule_id = data["schedule_id"]?.try(&.as_s?)
    return if schedule_id.nil?

    schedule = graph.get_object(schedule_id)
    return if schedule.nil?
    sdata = JSON.parse(schedule.data).as_h
    return unless sdata["enabled"]?.try(&.as_bool?) == true

    emit_type = sdata["payload_emit_type"]?.try(&.as_s?)
    return if emit_type.nil? || emit_type.empty?
    payload_body = sdata["payload_data"]?.try(&.as_h) || {} of String => JSON::Any

    # Traceability: every emitted object records the schedule and tick that
    # asked for it. Merged under metadata so payload_data stays the caller's.
    meta = payload_body["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    meta = meta.dup
    meta["schedule_id"] = JSON::Any.new(schedule_id)
    meta["tick_id"] = JSON::Any.new(tick_id)
    meta["fired_at"] = data["fired_at"]? || JSON::Any.new(nil)
    payload_body["metadata"] = JSON::Any.new(meta)
    payload_body["frame_id"] ||= data["frame_id"]? || JSON::Any.new(nil)

    # Heartbeats get their pulse sequence stamped for free.
    if emit_type == "heartbeat"
      payload_body["fired_at"] ||= data["fired_at"]? || JSON::Any.new(nil)
      fire_count = sdata["fire_count"]?.try(&.as_i?) || 0
      payload_body["sequence"] ||= JSON::Any.new(fire_count + 1)
      payload_body["schedule_id"] ||= JSON::Any.new(schedule_id)
    end

    emitted =
      begin
        graph.add_object(emit_type, payload_body.to_json, actor: "schedule.tick_router")
      rescue ex
        # Payload type not registered / schema mismatch: record why on the
        # tick — a schedule that can't act must fail visibly, not silently.
        begin
          tick_meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
          tick_meta = tick_meta.dup
          tick_meta["emit_skipped"] = JSON::Any.new("Error: #{ex.message}"[0, 300])
          _merge_patch(graph, tick_id.to_s, {"metadata" => JSON::Any.new(tick_meta)})
        rescue
        end
        return
      end

    begin
      graph.add_relation(emitted.id, schedule_id, "emitted_by", actor: "schedule.tick_router")
    rescue
    end
  end

  # Advance the schedule a tick just satisfied.
  @[Chronicle::Packs::Annotations::Behavior(name: "schedule_bookkeeper", on: ["object.created"], where: {"type" => "schedule_tick"}, creates: [] of String)]
  def schedule_bookkeeper(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ScheduleSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    schedule_id = data["schedule_id"]?.try(&.as_s?)
    fired_at = data["fired_at"]?.try(&.as_s?)
    return if schedule_id.nil? || fired_at.nil?

    schedule = graph.get_object(schedule_id)
    return if schedule.nil?
    sdata = JSON.parse(schedule.data).as_h

    patch = {
      "last_fired_at" => JSON::Any.new(fired_at),
      "fire_count"    => JSON::Any.new((sdata["fire_count"]?.try(&.as_i?) || 0) + 1),
    }
    if sdata["kind"]?.try(&.as_s?) == "once"
      patch["next_due_at"] = JSON::Any.new(nil)
      patch["enabled"] = JSON::Any.new(false)
    else
      patch["next_due_at"] = JSON::Any.new(
        compute_next_due(
          sdata["kind"]?.try(&.as_s?) || "",
          every_seconds: sdata["every_seconds"]?.try(&.as_i?),
          at_time: sdata["at_time"]?.try(&.as_s?),
          at: sdata["at"]?.try(&.as_s?),
          after: fired_at,
        )
      )
    end
    begin
      _merge_patch(graph, schedule_id, patch)
    rescue
    end
  end
end

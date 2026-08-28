require "json"
require "time"

module Chronicle::Packs::Schedule
  # Schedule Pack tools. Ported from upstream packs/schedule/tools.py.
  #
  # The clock stays at the edge: every function that needs to know what time
  # it is takes `now` (ISO 8601 string) as an argument. The `*_fn` functions
  # are the ported behavior and take the graph explicitly; declared tool
  # wrappers read a host-bound graph.

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._as_dt(now : String) : Time
    Time.parse_iso8601(now).to_utc
  end

  def self._iso(dt : Time) : String
    dt.to_utc.to_s("%Y-%m-%dT%H:%M:%S%:z")
  end

  # Next due moment strictly after `after`, per the schedule spec. Returns
  # nil for a 'once' schedule whose moment has passed.
  def self.compute_next_due(
    kind : String,
    *,
    every_seconds : Int32?,
    at_time : String?,
    at : String?,
    after : String,
  ) : String?
    ref = _as_dt(after)
    case kind
    when "interval"
      return nil if every_seconds.nil?
      _iso(ref + Time::Span.new(seconds: every_seconds.to_i64))
    when "daily"
      return nil if at_time.nil?
      parts = at_time.split(":", 2)
      return nil if parts.size < 2
      hh = parts[0].to_i
      mm = parts[1].to_i
      candidate = Time.utc(ref.year, ref.month, ref.day, hh, mm, 0)
      candidate += Time::Span.new(days: 1) if candidate <= ref
      _iso(candidate)
    when "once"
      return nil if at.nil?
      moment = _as_dt(at)
      moment > ref ? _iso(moment) : nil
    else
      nil
    end
  end

  # Create a Schedule with its initial next_due_at computed from `now`.
  def self.create_schedule_fn(
    graph : Chronicle::GraphProjection,
    *,
    name : String,
    kind : String,
    payload_emit_type : String,
    payload_data : Hash(String, JSON::Any)? = nil,
    every_seconds : Int32? = nil,
    at_time : String? = nil,
    at : String? = nil,
    now : String,
    enabled : Bool = true,
    created_by : String? = nil,
    frame_id : String? = nil,
    metadata : Hash(String, JSON::Any)? = nil,
  ) : Chronicle::GraphObject
    next_due =
      if kind == "once"
        if at && (at_moment = _as_dt(at)) > _as_dt(now)
          _iso(at_moment)
        else
          nil
        end
      else
        compute_next_due(kind, every_seconds: every_seconds, at_time: at_time, at: at, after: now)
      end

    graph.add_object("schedule", Schedule.new(
      name: name,
      kind: kind,
      every_seconds: every_seconds,
      at_time: at_time,
      at: at,
      payload_emit_type: payload_emit_type,
      payload_data: payload_data || {} of String => JSON::Any,
      enabled: enabled && !next_due.nil?,
      next_due_at: next_due,
      last_fired_at: nil,
      fire_count: 0,
      created_by: created_by,
      frame_id: frame_id,
      metadata: metadata || {} of String => JSON::Any,
    ).to_json, actor: "schedule")
  end

  # Enabled schedules whose next_due_at is at or before `now`.
  def self.list_due_fn(graph : Chronicle::GraphProjection, now : String) : Array(Hash(String, JSON::Any))
    ref = _as_dt(now)
    due = [] of Hash(String, JSON::Any)
    graph.objects(type: "schedule").each do |obj|
      data = JSON.parse(obj.data).as_h
      next unless data["enabled"]?.try(&.as_bool?) == true
      next if data["next_due_at"]?.nil?
      next unless data["next_due_at"].as_s? && _as_dt(data["next_due_at"].as_s) <= ref
      entry = data.dup
      entry["schedule_id"] = JSON::Any.new(obj.id)
      due << entry
    end
    due.sort_by { |entry| entry["next_due_at"]?.try(&.as_s?) || "" }
  end

  # Create a schedule_tick for every due schedule. Idempotent by dedup_key.
  def self.emit_due_ticks_fn(graph : Chronicle::GraphProjection, now : String) : Array(String)
    fired_iso = _iso(_as_dt(now))
    existing_keys = Set(String).new
    graph.objects(type: "schedule_tick").each do |tick|
      key = JSON.parse(tick.data).as_h["dedup_key"]?.try(&.as_s?)
      existing_keys << key if key
    end

    created = [] of String
    list_due_fn(graph, now).each do |due|
      key = "#{due["schedule_id"].as_s}@#{due["next_due_at"].as_s}"
      next if existing_keys.includes?(key)
      tick = graph.add_object("schedule_tick", ScheduleTick.new(
        schedule_id: due["schedule_id"].as_s,
        fired_at: fired_iso,
        due_at: due["next_due_at"].as_s,
        dedup_key: key,
        frame_id: nil,
        metadata: {} of String => JSON::Any,
      ).to_json, actor: "schedule")
      begin
        graph.add_relation(tick.id, due["schedule_id"].as_s, "tick_of", actor: "schedule")
      rescue
      end
      created << tick.id
    end
    created
  end

  # Enable or disable a schedule. Returns {"ok": bool, "reason": str}.
  def self.set_schedule_enabled_fn(graph : Chronicle::GraphProjection, schedule_id : String, enabled : Bool) : Hash(String, JSON::Any)
    obj = graph.get_object(schedule_id)
    return {"ok" => JSON::Any.new(false), "reason" => JSON::Any.new("no schedule #{schedule_id.inspect}")} if obj.nil? || obj.type != "schedule"
    begin
      _merge_patch(graph, schedule_id, {"enabled" => JSON::Any.new(enabled)})
    rescue
    end
    {"ok" => JSON::Any.new(true), "reason" => JSON::Any.new("updated")}
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "schedule tools require a bound graph (set Schedule.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "create_schedule", description: "Create a schedule (interval | daily | once) that emits a declared object on each firing. next_due_at is computed from the supplied 'now' — the caller owns the clock.", deterministic: true)]
  def create_schedule_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = create_schedule_fn(
      bound_graph_or_raise,
      name: input["name"]?.try(&.as_s?) || "",
      kind: input["kind"]?.try(&.as_s?) || "",
      payload_emit_type: input["payload_emit_type"]?.try(&.as_s?) || "",
      payload_data: input["payload_data"]?.try(&.as_h?) || nil,
      every_seconds: input["every_seconds"]?.try(&.as_i?),
      at_time: input["at_time"]?.try(&.as_s?),
      at: input["at"]?.try(&.as_s?),
      now: input["now"]?.try(&.as_s?) || "",
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "emit_due_ticks", description: "Create a schedule_tick for every schedule due at 'now' (idempotent by '{schedule_id}@{due_at}'). THE host-driver entry point.", deterministic: true)]
  def emit_due_ticks_tool(args : String) : String
    input = JSON.parse(args).as_h
    created = emit_due_ticks_fn(bound_graph_or_raise, input["now"]?.try(&.as_s?) || "")
    JSON.build do |json|
      json.array do
        created.each { |id| json.string id }
      end
    end
  end

  @[Chronicle::Packs::Annotations::Tool(name: "list_due_schedules", description: "List enabled schedules due at or before 'now'.", deterministic: true)]
  def list_due_schedules_tool(args : String) : String
    input = JSON.parse(args).as_h
    due = list_due_fn(bound_graph_or_raise, input["now"]?.try(&.as_s?) || "")
    JSON.build do |json|
      json.array do
        due.each { |entry| json.raw entry.to_json }
      end
    end
  end

  @[Chronicle::Packs::Annotations::Tool(name: "set_schedule_enabled", description: "Enable or disable a schedule by id.", deterministic: true)]
  # ameba:disable Naming/AccessorMethodName -- chronicle tool-name convention (`set_` prefix)
  def set_schedule_enabled_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = set_schedule_enabled_fn(
      bound_graph_or_raise,
      input["schedule_id"]?.try(&.as_s?) || "",
      input["enabled"]?.try(&.as_bool?) || false,
    )
    result.to_json
  end
end

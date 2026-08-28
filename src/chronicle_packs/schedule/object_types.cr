require "json"

module Chronicle::Packs::Schedule
  # Schedule Pack object types. Ported from upstream
  # packs/schedule/object_types.py. Time, made graph-native: a `schedule`
  # declares when to fire and what to emit; a `schedule_tick` records that a
  # due moment arrived; a `heartbeat` is a periodic pulse for housekeeping
  # behaviors to subscribe to. No clock, no thread, no loop in the pack.

  # A declared recurrence: when to fire (interval | daily | once) and what
  # object to emit on each firing.
  @[Chronicle::Packs::Annotations::ObjectType(name: "schedule")]
  struct Schedule
    include JSON::Serializable
    include Chronicle::Packs::CopyWith

    getter name : String
    getter kind : String
    getter every_seconds : Int32? = nil
    getter at_time : String? = nil
    getter at : String? = nil
    getter payload_emit_type : String
    getter payload_data : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter? enabled : Bool = true
    getter next_due_at : String? = nil
    getter last_fired_at : String? = nil
    getter fire_count : Int32 = 0
    getter created_by : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @name : String,
      @kind : String,
      @payload_emit_type : String,
      @every_seconds : Int32? = nil,
      @at_time : String? = nil,
      @at : String? = nil,
      @payload_data : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @enabled : Bool = true,
      @next_due_at : String? = nil,
      @last_fired_at : String? = nil,
      @fire_count : Int32 = 0,
      @created_by : String? = nil,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    define_copy_with
  end

  # The event-first record that a schedule's due moment arrived. Deduped by
  # '{schedule_id}@{due_at}'.
  @[Chronicle::Packs::Annotations::ObjectType(name: "schedule_tick")]
  struct ScheduleTick
    include JSON::Serializable

    getter schedule_id : String
    getter fired_at : String
    getter due_at : String
    getter dedup_key : String
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @schedule_id : String,
      @fired_at : String,
      @due_at : String,
      @dedup_key : String,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A periodic pulse other packs can subscribe to. Deliberately empty of
  # domain meaning.
  @[Chronicle::Packs::Annotations::ObjectType(name: "heartbeat")]
  struct Heartbeat
    include JSON::Serializable

    getter fired_at : String
    getter sequence : Int32 = 0
    getter schedule_id : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @fired_at : String,
      @sequence : Int32 = 0,
      @schedule_id : String? = nil,
      @frame_id : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end

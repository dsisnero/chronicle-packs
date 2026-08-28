require "chronicle"
require "json"

module Chronicle::Packs::Schedule
  # Schedule Pack gateway capabilities (upstream packs/schedule/capabilities.py).
  #
  # Registers schedule creation as a Tool Gateway capability, which is what
  # makes "remind me tomorrow at 9am" a one-turn chat interaction: expose
  # `schedule.create_reminder` in `ChatSettings.tool_allow_list` and the LLM
  # proposes it through the gateway — recorded, policy-checked, audited —
  # like any other capability.
  #
  # Upstream's handler receives the graph handle via `execution_context`;
  # the ported gateway passes input_data only (the ported gateway decouples
  # graph injection), so the handler reads the graph bound by the host via
  # `bound_graph` — the established capability-pattern seam (same as mcp /
  # communication tools).
  module Capabilities
    # The graph the reminder capability operates on, bound by the host.
    class_property bound_graph : Chronicle::GraphProjection? = nil

    private def self.bound_graph_or_raise : Chronicle::GraphProjection
      bound_graph || raise Chronicle::Packs::PackError.new("schedule capabilities require a bound graph (set Schedule::Capabilities.bound_graph)")
    end

    # What the model supplies to schedule a reminder.
    struct CreateReminderInput
      include JSON::Serializable

      getter message : String
      getter at : String?
      getter every_seconds : Int32?
      getter channel : String = "chat"
      getter thread_id : String?

      def initialize(
        @message : String = "",
        @at : String? = nil,
        @every_seconds : Int32? = nil,
        @channel : String = "chat",
        @thread_id : String? = nil,
      )
      end
    end

    # The reminder payload is a `comm_response_candidate` (status=approved):
    # when the schedule fires, the channel's dispatcher delivers it exactly
    # like any other approved outbound reply. Action class R3 (see upstream
    # ADR 0016 discipline).
    def self.register_reminder_capability(*, risk_class : String = "low") : ToolGateway::CapabilitySpec?
      _create_reminder = ->(input : Hash(String, JSON::Any)) {
        graph = bound_graph_or_raise
        at = input["at"]?.try(&.as_s?)
        every_seconds = input["every_seconds"]?.try(&.as_i?)
        if at.nil? && every_seconds.nil?
          return {"ok" => JSON::Any.new(false), "reason" => JSON::Any.new("provide 'at' (once) or 'every_seconds' (recurring)")}
        end
        message = input["message"]?.try(&.as_s?) || ""
        channel = input["channel"]?.try(&.as_s?) || "chat"
        thread_id = input["thread_id"]?.try(&.as_s?)

        kind = at.nil? ? "interval" : "once"
        schedule = Chronicle::Packs::Schedule.create_schedule_fn(
          graph,
          name: "reminder: #{message[0, 40]}",
          kind: kind,
          at: at,
          every_seconds: every_seconds,
          payload_emit_type: "comm_response_candidate",
          payload_data: {
            "message_id"          => JSON::Any.new(""),
            "thread_id"           => thread_id ? JSON::Any.new(thread_id) : JSON::Any.new(nil),
            "channel"             => JSON::Any.new(channel),
            "content"             => JSON::Any.new(message),
            "status"              => JSON::Any.new("approved"),
            "created_by_behavior" => JSON::Any.new("schedule.tick_router"),
            "metadata"            => JSON::Any.new({"reminder" => JSON::Any.new(true)}),
          },
          now: Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ"),
          created_by: "schedule.create_reminder",
        )
        schedule_data = JSON.parse(schedule.data).as_h
        {
          "ok"          => JSON::Any.new(true),
          "schedule_id" => JSON::Any.new(schedule.id),
          "kind"        => JSON::Any.new(kind),
          "next_due_at" => schedule_data["next_due_at"]? || JSON::Any.new(nil),
        }
      }

      ToolGateway.register_local_capability(
        "schedule", "create_reminder", _create_reminder,
        description: "Schedule a reminder for the user: one-shot ('at', ISO 8601 UTC) or recurring ('every_seconds'). Delivered on the given channel when due.",
        risk_class: risk_class,
        action_class: "R3",
        input_schema: JSON.parse(%({"type":"object","properties":{"message":{"type":"string"},"at":{"type":"string"},"every_seconds":{"type":"integer"},"channel":{"type":"string"},"thread_id":{"type":"string"}},"required":["message"]})),
      )
    end
  end
end

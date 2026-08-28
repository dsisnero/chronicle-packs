require "json"

module Chronicle::Packs::Meeting
  # Meeting Pack tools. Ported from upstream packs/meeting/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Create a meeting_transcript source, triggering transcript_ingester.
  def self.ingest_transcript_fn(
    graph : Chronicle::GraphProjection,
    title : String,
    content : String = "",
    date : String? = nil,
    participants : Array(String)? = nil,
    platform : String = "other",
    duration_minutes : Int32? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("source", {
      "kind"     => JSON::Any.new("meeting_transcript"),
      "content"  => JSON::Any.new(content),
      "channel"  => JSON::Any.new("meeting"),
      "metadata" => JSON::Any.new({
        "title"            => JSON::Any.new(title),
        "date"             => JSON::Any.new(date),
        "participants"     => JSON::Any.new((participants || [] of String).map { |participant| JSON::Any.new(participant) }),
        "platform"         => JSON::Any.new(platform),
        "duration_minutes" => JSON::Any.new(duration_minutes),
      }),
    }.to_json, actor: "meeting")
  end

  # Directly create a Meeting object (without transcript).
  def self.create_meeting_fn(
    graph : Chronicle::GraphProjection,
    title : String,
    date : String? = nil,
    participants : Array(String)? = nil,
    platform : String = "other",
    duration_minutes : Int32? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("meeting", Meeting.new(
      title: title,
      date: date,
      duration_minutes: duration_minutes,
      platform: MeetingPlatform.parse?(platform) || MeetingPlatform::Other,
      participants: participants || [] of String,
      status: MeetingStatus::Completed,
    ).to_json, actor: "meeting")
  end

  # Manually add a MeetingDecision to an existing meeting.
  def self.add_decision_fn(
    graph : Chronicle::GraphProjection,
    meeting_id : String,
    text : String,
    decided_by : Array(String)? = nil,
    confidence : Float64 = 0.85,
  ) : Chronicle::GraphObject
    decision = graph.add_object("meeting_decision", MeetingDecision.new(
      meeting_id: meeting_id,
      text: text,
      decided_by: decided_by || [] of String,
      confidence: confidence,
    ).to_json, actor: "meeting")
    begin
      graph.add_relation(decision.id, meeting_id, "decision_in", actor: "meeting")
    rescue
    end
    decision
  end

  # Manually add a MeetingActionItem and optionally create a Core task.
  def self.add_action_item_fn(
    graph : Chronicle::GraphProjection,
    meeting_id : String,
    text : String,
    owner_ref : String? = nil,
    due_at : String? = nil,
    create_task : Bool = true,
  ) : Chronicle::GraphObject
    task_id : String? = nil
    if create_task
      task = graph.add_object("task", {
        "title"       => JSON::Any.new("[Meeting] #{text[0, 60]}"),
        "description" => JSON::Any.new(text),
        "status"      => JSON::Any.new("candidate"),
        "priority"    => JSON::Any.new("medium"),
        "owner_ref"   => JSON::Any.new(owner_ref),
        "due_at"      => JSON::Any.new(due_at),
      }.to_json, actor: "meeting")
      task_id = task.id
    end

    action_item = graph.add_object("meeting_action_item", MeetingActionItem.new(
      meeting_id: meeting_id,
      text: text,
      owner_ref: owner_ref,
      due_at: due_at,
      task_id: task_id,
      status: ActionItemStatus::Open,
    ).to_json, actor: "meeting")
    begin
      graph.add_relation(action_item.id, meeting_id, "action_item_in", actor: "meeting")
    rescue
    end
    if task_id
      begin
        graph.add_relation(action_item.id, task_id, "action_creates_task", actor: "meeting")
      rescue
      end
    end
    action_item
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "meeting tools require a bound graph (set Meeting.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "ingest_transcript", description: "Ingest a meeting transcript to extract decisions and action items.", deterministic: true)]
  def ingest_transcript_tool(args : String) : String
    input = JSON.parse(args).as_h
    participants = input["participants"]?.try(&.as_a?)
    result = ingest_transcript_fn(
      bound_graph_or_raise,
      input["title"]?.try(&.as_s?) || "",
      content: input["content"]?.try(&.as_s?) || "",
      date: input["date"]?.try(&.as_s?),
      participants: participants.try { |arr| arr.map(&.as_s) },
      platform: input["platform"]?.try(&.as_s?) || "other",
      duration_minutes: input["duration_minutes"]?.try(&.as_i?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_meeting", description: "Create a meeting record (without transcript).", deterministic: true)]
  def create_meeting_tool(args : String) : String
    input = JSON.parse(args).as_h
    participants = input["participants"]?.try(&.as_a?)
    result = create_meeting_fn(
      bound_graph_or_raise,
      input["title"]?.try(&.as_s?) || "",
      date: input["date"]?.try(&.as_s?),
      participants: participants.try { |arr| arr.map(&.as_s) },
      platform: input["platform"]?.try(&.as_s?) || "other",
      duration_minutes: input["duration_minutes"]?.try(&.as_i?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "add_decision", description: "Add a decision to an existing meeting.", deterministic: true)]
  def add_decision_tool(args : String) : String
    input = JSON.parse(args).as_h
    decided_by = input["decided_by"]?.try(&.as_a?)
    result = add_decision_fn(
      bound_graph_or_raise,
      input["meeting_id"]?.try(&.as_s?) || "",
      input["text"]?.try(&.as_s?) || "",
      decided_by: decided_by.try { |arr| arr.map(&.as_s) },
      confidence: input["confidence"]?.try(&.as_f?) || 0.85,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "add_action_item", description: "Add an action item to a meeting and create a Core task.", deterministic: true)]
  def add_action_item_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = add_action_item_fn(
      bound_graph_or_raise,
      input["meeting_id"]?.try(&.as_s?) || "",
      input["text"]?.try(&.as_s?) || "",
      owner_ref: input["owner_ref"]?.try(&.as_s?),
      due_at: input["due_at"]?.try(&.as_s?),
      create_task: input["create_task"]?.try(&.as_bool?) || true,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end
end

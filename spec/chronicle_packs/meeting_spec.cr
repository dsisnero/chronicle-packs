require "spec"
require "../spec_helper"

# Meeting Pack (packs/meeting): transcript ingestion, decision extraction,
# action item extraction with Core task creation, and meeting summarization.
# Translated from upstream packs/meeting/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). All v0.1 behaviors are
# deterministic (mock stubs, no LLM/API key).

module MeetingSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def meeting_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "meeting" / "manifest.toml"
  end

  # Mirrors upstream fixtures/run_fixtures.py: Core + meeting with
  # min_segment_words=4 and both auto-create/auto-summarize on.
  def with_meeting_runtime(
    min_segment_words : Int32 = 4,
    auto_create_tasks : Bool = true,
    auto_summarize : Bool = true,
    &
  )
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::Meeting::MeetingSettings.new(
      min_segment_words: min_segment_words,
      auto_create_tasks_from_action_items: auto_create_tasks,
      auto_summarize_meeting: auto_summarize,
    )
    rt.load_pack(Chronicle::Packs::Meeting.pack, JSON.parse(settings.to_json).as_h).should be_true
    Chronicle::Packs::Meeting.clear_meeting_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Meeting.clear_meeting_registry
  end

  # Mirrors upstream fixtures/run_fixtures.py SAMPLE_TRANSCRIPT (structured
  # 'Speaker: text' export). 10 segments: 6 decision-flagged, 4 action-flagged.
  SAMPLE_TRANSCRIPT = "Alice: Good morning everyone. Let's get started with the sprint review.\n" \
                      "Bob: We completed the database migration last week. All tests are passing.\n" \
                      "Alice: Great work. We decided to move to PostgreSQL 16 for all new services going forward.\n" \
                      "Carol: I'll follow up with the infrastructure team about the upgrade timeline.\n" \
                      "Bob: Action item: Bob will write the migration runbook by next Friday.\n" \
                      "Alice: We also need to update the API documentation. Carol, can you take that on?\n" \
                      "Carol: Sure, I'll have that done by end of week.\n" \
                      "Alice: One more thing — we decided to adopt feature flags for all new releases going forward.\n" \
                      "Bob: I'll set up the LaunchDarkly integration by Thursday. That's my action item.\n" \
                      "Alice: Perfect. Let's wrap up. Summary: migration done, feature flags incoming, docs update in progress.\n"

  def ingest_sample_transcript(graph, title : String = "Sprint Review — Week 23", min_words : Int32 = 4)
    Chronicle::Packs::Meeting.ingest_transcript_fn(
      graph,
      title: title,
      content: SAMPLE_TRANSCRIPT,
      date: "2026-06-03",
      participants: ["Alice", "Bob", "Carol"],
      platform: "zoom",
      duration_minutes: 30,
    )
  end
end

include MeetingSpecSupport

describe Chronicle::Packs::Meeting do
  describe "manifest-declared surface" do
    it "matches the upstream meeting manifest" do
      pack = Chronicle::Packs::Meeting.pack
      pack.name.should eq("meeting")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["meeting", "transcript_segment", "meeting_decision", "meeting_action_item", "meeting_note"]
      )
      pack.relation_types.map(&.name).should eq(
        ["segment_of", "decision_in", "action_item_in", "note_for", "decision_from_segment", "action_item_from_segment", "action_creates_task"]
      )
      pack.behaviors.map(&.name).should eq(
        ["transcript_ingester", "decision_extractor", "action_item_extractor", "meeting_summarizer"]
      )
      pack.tools.map(&.name).should eq(["ingest_transcript", "create_meeting", "add_decision", "add_action_item"])
      pack.settings_schema.should eq("MeetingSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(meeting_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Meeting.pack)
    end

    it "round-trips the closed-set meeting enums as underscored names" do
      Chronicle::Packs::Meeting::MeetingPlatform::GoogleMeet.to_json.should eq(%("google_meet"))
      Chronicle::Packs::Meeting::MeetingPlatform::InPerson.to_json.should eq(%("in_person"))
      Chronicle::Packs::Meeting::MeetingStatus::Completed.to_json.should eq(%("completed"))
      Chronicle::Packs::Meeting::ActionItemStatus::Cancelled.to_json.should eq(%("cancelled"))
      Chronicle::Packs::Meeting::NoteType::Highlights.to_json.should eq(%("highlights"))
    end
  end

  describe "fixture: transcript_ingestion_pipeline" do
    it "turns a meeting_transcript source into Meeting + Segments + Decisions + ActionItems + Note + Core tasks" do
      with_meeting_runtime do |_store, graph, rt|
        ingest_sample_transcript(graph)
        rt.run_until_idle

        meetings = graph.objects(type: "meeting")
        meetings.size.should eq(1)
        meeting_data = JSON.parse(meetings.first.data)
        meeting_data["title"].as_s.should eq("Sprint Review — Week 23")
        meeting_data["date"].as_s.should eq("2026-06-03")
        meeting_data["platform"].as_s.should eq("zoom")
        meeting_data["duration_minutes"].as_i.should eq(30)
        meeting_data["participants"].as_a.map(&.as_s).should eq(["Alice", "Bob", "Carol"])
        meeting_data["status"].as_s.should eq("completed")
        meeting_data["source_id"].as_s.should eq(graph.objects(type: "source").first.id)

        segments = graph.objects(type: "transcript_segment")
        segments.size.should eq(10)
        decision_flags = segments.select { |s| JSON.parse(s.data)["is_decision"]?.try(&.as_bool?) == true }
        action_flags = segments.select { |s| JSON.parse(s.data)["is_action_item"]?.try(&.as_bool?) == true }
        decision_flags.size.should eq(6)
        action_flags.size.should eq(4)

        decisions = graph.objects(type: "meeting_decision")
        decisions.size.should eq(6)
        JSON.parse(decisions.first.data)["confidence"].as_f.should eq(0.80)
        decisions.each do |d|
          JSON.parse(d.data)["meeting_id"].as_s.should eq(meetings.first.id)
        end

        action_items = graph.objects(type: "meeting_action_item")
        action_items.size.should eq(4)
        action_items.each do |a|
          JSON.parse(a.data)["status"].as_s.should eq("open")
        end
        owner_refs = action_items.map { |a| JSON.parse(a.data)["owner_ref"]?.try(&.as_s?) }
        owner_refs.should contain("Bob")
        owner_refs.should contain("Carol")
        owner_refs.none?(&.nil?).should be_true

        tasks = graph.objects(type: "task")
        tasks.size.should eq(4)
        JSON.parse(tasks.first.data)["status"].as_s.should eq("candidate")
        JSON.parse(tasks.first.data)["title"].as_s.should start_with("[Meeting] ")

        notes = graph.objects(type: "meeting_note")
        notes.size.should eq(1)
        JSON.parse(notes.first.data)["note_type"].as_s.should eq("summary")
        JSON.parse(notes.first.data)["content"].as_s.should contain("Meeting Summary: Sprint Review — Week 23")

        rel_types = graph.relations.map(&.type).to_set
        rel_types.should contain("derived_from_source")
        rel_types.should contain("segment_of")
        rel_types.should contain("decision_in")
        rel_types.should contain("decision_from_segment")
        rel_types.should contain("action_item_in")
        rel_types.should contain("action_item_from_segment")
        rel_types.should contain("action_creates_task")
        rel_types.should contain("note_for")
        graph.relations.select { |r| r.type == "segment_of" }.size.should eq(10)
        graph.relations.select { |r| r.type == "decision_in" }.size.should eq(6)
        graph.relations.select { |r| r.type == "action_creates_task" }.size.should eq(4)
      end
    end

    it "creates no action items or tasks when auto_create_tasks_from_action_items is false" do
      with_meeting_runtime(auto_create_tasks: false) do |_store, graph, rt|
        ingest_sample_transcript(graph)
        rt.run_until_idle

        # Upstream action_item_extractor returns before creating anything when
        # task auto-creation is disabled (the gate precedes both objects).
        graph.objects(type: "meeting_action_item").size.should eq(0)
        graph.objects(type: "task").size.should eq(0)
      end
    end

    it "accepts a JSON-array transcript export (Zoom/Teams style)" do
      with_meeting_runtime do |_store, graph, rt|
        Chronicle::Packs::Meeting.ingest_transcript_fn(
          graph,
          title: "Sprint Review — Week 23",
          content: %([{"speaker":"Alice","text":"We decided to adopt feature flags going forward.","timestamp":0.0},{"speaker":"Bob","text":"I'll write the migration runbook by next Friday.","timestamp":12.5}]),
          date: "2026-06-03",
          participants: ["Alice", "Bob"],
          platform: "teams",
        )
        rt.run_until_idle

        meetings = graph.objects(type: "meeting")
        meetings.size.should eq(1)
        JSON.parse(meetings.first.data)["platform"].as_s.should eq("teams")

        segments = graph.objects(type: "transcript_segment")
        segments.size.should eq(2)
        decision_flags = segments.select { |s| JSON.parse(s.data)["is_decision"]?.try(&.as_bool?) == true }
        action_flags = segments.select { |s| JSON.parse(s.data)["is_action_item"]?.try(&.as_bool?) == true }
        decision_flags.size.should eq(1)
        action_flags.size.should eq(1)

        graph.objects(type: "meeting_decision").size.should eq(1)
        graph.objects(type: "meeting_action_item").size.should eq(1)
      end
    end

    it "does not re-ingest the same source id twice" do
      with_meeting_runtime do |_store, graph, rt|
        payload = JSON.build do |json|
          json.object do
            json.field "id", "src_meeting_dedup"
            json.field "type", "source"
            json.field "data" do
              json.object do
                json.field "kind", "meeting_transcript"
                json.field "content", SAMPLE_TRANSCRIPT
                json.field "channel", "meeting"
                json.field "metadata" do
                  json.object do
                    json.field "title", "Dedup Meeting"
                    json.field "date", "2026-06-04"
                    json.field "participants", [] of String
                    json.field "platform", "other"
                  end
                end
              end
            end
          end
        end
        event = Chronicle::Event.new(
          schema_version: 1, sequence: 1, id: "evt_meeting_dedup",
          type: "object.created", actor: "meeting", caused_by: nil, payload: payload
        )
        ctx = Chronicle::Packs::BehaviorContext.new(
          "meeting",
          JSON.parse(Chronicle::Packs::Meeting::MeetingSettings.new.to_json).as_h,
          ->(pack_name : String) { nil.as(Hash(String, JSON::Any)?) }
        )
        settings = Chronicle::Packs::Meeting::MeetingSettings.new(min_segment_words: 4)
        Chronicle::Packs::Meeting.transcript_ingester(event, graph, ctx, settings)
        Chronicle::Packs::Meeting.transcript_ingester(event, graph, ctx, settings)
        rt.run_until_idle

        graph.objects(type: "meeting").size.should eq(1)
        graph.objects(type: "transcript_segment").size.should eq(10)
      end
    end
  end

  describe "fixture: manual_meeting_workflow" do
    it "creates a meeting, auto-summarizes, and adds decisions + action items via tools" do
      with_meeting_runtime do |_store, graph, rt|
        meeting = Chronicle::Packs::Meeting.create_meeting_fn(
          graph,
          title: "Quarterly Planning — Q3 2026",
          date: "2026-07-01",
          participants: ["CEO", "CTO", "Head of Product"],
          platform: "google_meet",
          duration_minutes: 90,
        )
        rt.run_until_idle

        notes = graph.objects(type: "meeting_note")
        notes.size.should eq(1)
        note_data = JSON.parse(notes.first.data)
        note_data["meeting_id"].as_s.should eq(meeting.id)
        note_data["note_type"].as_s.should eq("summary")
        note_data["content"].as_s.should contain("Meeting Summary: Quarterly Planning — Q3 2026")

        Chronicle::Packs::Meeting.add_decision_fn(
          graph,
          meeting_id: meeting.id,
          text: "We decided to prioritize the mobile app rewrite for Q3.",
          decided_by: ["CEO", "CTO"],
          confidence: 0.95,
        )
        rt.run_until_idle
        Chronicle::Packs::Meeting.add_decision_fn(
          graph,
          meeting_id: meeting.id,
          text: "Marketing budget increased by 20% for Q3 campaigns.",
          decided_by: ["CEO"],
          confidence: 0.90,
        )
        rt.run_until_idle

        ai1 = Chronicle::Packs::Meeting.add_action_item_fn(
          graph,
          meeting_id: meeting.id,
          text: "CTO to produce technical spec for mobile app rewrite by July 15",
          owner_ref: "cto@acme.com",
          due_at: "2026-07-15",
          create_task: true,
        )
        rt.run_until_idle
        Chronicle::Packs::Meeting.add_action_item_fn(
          graph,
          meeting_id: meeting.id,
          text: "Head of Product to define Q3 OKRs by July 8",
          owner_ref: "product@acme.com",
          due_at: "2026-07-08",
          create_task: true,
        )
        rt.run_until_idle

        decisions = graph.objects(type: "meeting_decision")
        decisions.size.should eq(2)
        confidences = decisions.map { |d| JSON.parse(d.data)["confidence"].as_f }
        confidences.should contain(0.95)
        confidences.should contain(0.90)
        decided_bys = decisions.map { |d| JSON.parse(d.data)["decided_by"].as_a.map(&.as_s) }
        decided_bys.should contain(["CEO", "CTO"])
        decided_bys.should contain(["CEO"])

        action_items = graph.objects(type: "meeting_action_item")
        action_items.size.should eq(2)
        action_items.each do |a|
          data = JSON.parse(a.data)
          data["task_id"].as_s.should_not be_empty
          data["owner_ref"].as_s.should_not be_empty
        end

        tasks = graph.objects(type: "task")
        tasks.size.should eq(2)
        task_owners = tasks.map { |t| JSON.parse(t.data)["owner_ref"]?.try(&.as_s?) }
        task_owners.should contain("cto@acme.com")
        task_owners.should contain("product@acme.com")

        graph.relations.select { |r| r.type == "decision_in" }.size.should eq(2)
        graph.relations.select { |r| r.type == "action_item_in" }.size.should eq(2)
        graph.relations.select { |r| r.type == "action_creates_task" }.size.should eq(2)
        graph.relations.select { |r| r.type == "note_for" }.size.should eq(1)
        graph.objects(type: "meeting_note").size.should eq(1)
      end
    end

    it "skips task creation for a manual action item when create_task is false" do
      with_meeting_runtime do |_store, graph, rt|
        meeting = Chronicle::Packs::Meeting.create_meeting_fn(graph, title: "Standup", date: "2026-07-02")
        rt.run_until_idle

        ai = Chronicle::Packs::Meeting.add_action_item_fn(
          graph,
          meeting_id: meeting.id,
          text: "Follow up with infra",
          owner_ref: "cto@acme.com",
          create_task: false,
        )
        rt.run_until_idle

        data = JSON.parse(graph.get_object(ai.id).not_nil!.data)
        data["task_id"]?.try(&.as_s?).should be_nil
        graph.objects(type: "task").size.should eq(0)
        graph.relations.select { |r| r.type == "action_creates_task" }.size.should eq(0)
      end
    end
  end
end

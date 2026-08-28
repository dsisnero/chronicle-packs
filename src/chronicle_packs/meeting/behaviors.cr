require "json"
require "time"

module Chronicle::Packs::Meeting
  # Meeting Pack behaviors. Ported from upstream packs/meeting/behaviors.py.
  #
  # transcript_ingester    — source.created (kind=meeting_transcript) → Meeting
  #                          + TranscriptSegments
  # decision_extractor     — transcript_segment.created (is_decision) →
  #                          MeetingDecision
  # action_item_extractor  — transcript_segment.created (is_action_item) →
  #                          MeetingActionItem + Core Task
  # meeting_summarizer     — meeting.created → MeetingNote (summary)
  #
  # All v0.1 LLM behaviors are deterministic mock stubs (no API key).
  #
  # Transcript formats supported by transcript_ingester:
  #   1. JSON array:  [{"speaker": "...", "text": "...", "timestamp": 0.0}, ...]
  #   2. JSON object: {"segments": [...], "metadata": {...}}
  #   3. Structured text: "Speaker: text" lines (Zoom/Teams plain export)
  #   4. Plain text: paragraph/sentence splitting fallback
  #
  # Registries (class-level, cleared between fixtures via
  # clear_meeting_registry):
  #   meeting_registry:     source_id → meeting_id
  #   meeting_segment_count: meeting_id → segment_count

  # source_id → meeting_id.
  class_property meeting_registry = {} of String => String
  # meeting_id → segment_count.
  class_property meeting_segment_count = {} of String => Int32

  # Reset all registries — call between test fixtures.
  def self.clear_meeting_registry : Nil
    self.meeting_registry = {} of String => String
    self.meeting_segment_count = {} of String => Int32
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Parse JSON transcript format (Zoom/Teams export). Accepted shapes:
  # Array, or Object with segments/utterances/turns. Returns segment hashes,
  # or nil if content is not valid JSON or has no recognisable segment data.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _parse_json_transcript shape branches
  def self._parse_json_transcript(content : String) : Array(Hash(String, JSON::Any))?
    stripped = content.strip
    return nil unless stripped.starts_with?("[") || stripped.starts_with?("{")
    parsed =
      begin
        JSON.parse(stripped)
      rescue JSON::ParseException
        return nil
      end

    raw : Array(JSON::Any)
    if arr = parsed.as_a?
      raw = arr
    elsif h = parsed.as_h?
      found = h["segments"]? || h["utterances"]? || h["turns"]?
      raw = found.try(&.as_a?) || [] of JSON::Any
    else
      raw = [] of JSON::Any
    end

    return nil if raw.empty?

    segments = [] of Hash(String, JSON::Any)
    raw.each_with_index do |item, i|
      h = item.as_h?
      next if h.nil?
      text_v = h["text"]? || h["transcript"]? || h["content"]?
      text = text_v.try(&.as_s?) || ""
      next if text.empty?
      speaker_v = h["speaker"]? || h["speaker_label"]? || h["name"]?
      speaker = speaker_v.try(&.as_s?) || "Participant"
      ts_v = h["timestamp"]? || h["start"]? || h["start_time"]?
      timestamp_seconds =
        if ts_v.nil? || ts_v.raw.nil?
          nil
        else
          f = ts_v.as_f? || ts_v.as_i?.try(&.to_f)
          f.nil? || f == 0.0 ? nil : f
        end
      segments << {
        "speaker"           => JSON::Any.new(speaker),
        "text"              => JSON::Any.new(text),
        "segment_index"     => JSON::Any.new(i),
        "timestamp_seconds" => timestamp_seconds ? JSON::Any.new(timestamp_seconds) : JSON::Any.new(nil),
      }
    end
    segments.empty? ? nil : segments
  end

  # Parse speaker-labelled transcript: 'Speaker: text' lines.
  def self._parse_structured_transcript(content : String) : Array(Hash(String, JSON::Any))
    segments = [] of Hash(String, JSON::Any)
    content.split("\n").each_with_index do |raw_line, i|
      line = raw_line.strip
      next if line.empty?
      if m = line.match(/^([A-Za-z][^:]{1,40}):\s*(.+)$/)
        segments << {
          "speaker"       => JSON::Any.new(m[1].strip),
          "text"          => JSON::Any.new(m[2].strip),
          "segment_index" => JSON::Any.new(i),
        }
      elsif !segments.empty?
        segments.last["text"] = JSON::Any.new(segments.last["text"].as_s + " " + line)
      end
    end
    segments
  end

  # Split plain text transcript into sentence-based segments.
  def self._parse_plain_transcript(content : String, max_segments : Int32) : Array(Hash(String, JSON::Any))
    sentences = content.strip.split(/(?<=[.!?])\s+/)
    segments = [] of Hash(String, JSON::Any)
    sentences.each_with_index do |raw_sentence, i|
      break if i >= max_segments
      sentence = raw_sentence.strip
      next if sentence.split.size < 3
      segments << {
        "speaker"       => JSON::Any.new("Participant"),
        "text"          => JSON::Any.new(sentence),
        "segment_index" => JSON::Any.new(i),
      }
    end
    segments
  end

  def self._contains_decision(text : String, keywords : Array(String)) : Bool
    text_lower = text.downcase
    keywords.any? { |keyword| text_lower.includes?(keyword.downcase) }
  end

  def self._contains_action_item(text : String, keywords : Array(String)) : Bool
    text_lower = text.downcase
    keywords.any? { |keyword| text_lower.includes?(keyword.downcase) }
  end

  # Try to find a participant name mentioned in the text (upstream
  # _extract_owner_ref).
  def self._extract_owner_ref(text : String, participants : Array(String)) : String?
    text_lower = text.downcase
    participants.find { |participant| text_lower.includes?(participant.downcase) }
  end

  # Deterministic mock summary (upstream _mock_summary). Not currently used
  # by the v0.1 behaviors; ported for surface parity.
  def self._mock_summary(meeting_title : String, decisions : Array(String), action_items : Array(String)) : String
    lines = ["# Meeting Summary: #{meeting_title}\n"]
    if decisions.empty?
      lines << "## Decisions\nNo decisions recorded.\n"
    else
      lines << "## Decisions\n"
      decisions.each { |decision| lines << "- #{decision}" }
    end
    if action_items.empty?
      lines << "\n## Action Items\nNo action items recorded.\n"
    else
      lines << "\n## Action Items\n"
      action_items.each { |item| lines << "- #{item}" }
    end
    lines << "\n## Notes\nSummary generated by meeting_summarizer (v0.1 mock)."
    lines.join("\n")
  end

  # Ingest a meeting transcript source into Meeting + TranscriptSegment objects.
  @[Chronicle::Packs::Annotations::Behavior(name: "transcript_ingester", on: ["object.created"], where: {"type" => "source"}, creates: ["meeting", "transcript_segment"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream transcript_ingester format/segment branches
  def transcript_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MeetingSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless data["kind"]?.try(&.as_s?) == "meeting_transcript"
    return if meeting_registry.has_key?(source_id)

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    content = data["content"]?.try(&.as_s?) || ""
    title = meta["title"]?.try(&.as_s?)
    title = "Untitled Meeting" if title.nil? || title.empty?
    date = meta["date"]?.try(&.as_s?)
    date = meta["received_at"]?.try(&.as_s?) if date.nil? || date.empty?
    date = _now_iso[0, 10] if date.nil? || date.empty?
    participants = meta["participants"]?.try(&.as_a?) ? meta["participants"].as_a.map(&.as_s) : [] of String
    platform = meta["platform"]?.try(&.as_s?) || "other"
    duration = meta["duration_minutes"]?.try(&.as_i?)

    # ── Create Meeting ────────────────────────────────────────────────────
    begin
      meeting = graph.add_object("meeting", Meeting.new(
        title: title,
        date: date,
        duration_minutes: duration,
        platform: MeetingPlatform.parse?(platform) || MeetingPlatform::Other,
        participants: participants,
        source_id: source_id,
        status: MeetingStatus::Completed,
      ).to_json, actor: "meeting.transcript_ingester")
      meeting_id = meeting.id
      meeting_registry[source_id] = meeting_id
      meeting_segment_count[meeting_id] = 0
      graph.add_relation(meeting_id, source_id, "derived_from_source", actor: "meeting.transcript_ingester")
    rescue
      return
    end

    # ── Parse transcript — try formats in priority order ──────────────────
    raw_segments =
      _parse_json_transcript(content) ||
        (
          if content.match(/^[A-Za-z][^:]{1,40}:\s/m)
            _parse_structured_transcript(content)
          else
            nil
          end
        ) ||
        _parse_plain_transcript(content, settings.max_segments_per_meeting)

    raw_segments.first(settings.max_segments_per_meeting).each do |seg_data|
      text = seg_data["text"]?.try(&.as_s?) || ""
      next if text.split.size < settings.min_segment_words

      has_decision = _contains_decision(text, settings.decision_keywords)
      has_action = _contains_action_item(text, settings.action_item_keywords)

      begin
        seg = graph.add_object("transcript_segment", TranscriptSegment.new(
          meeting_id: meeting_id,
          speaker: seg_data["speaker"]?.try(&.as_s?) || "Participant",
          text: text,
          segment_index: seg_data["segment_index"]?.try(&.as_i?) || 0,
          timestamp_seconds: seg_data["timestamp_seconds"]?.try(&.as_f?),
          is_decision: has_decision,
          is_action_item: has_action,
        ).to_json, actor: "meeting.transcript_ingester")
        graph.add_relation(seg.id, meeting_id, "segment_of", actor: "meeting.transcript_ingester")
        meeting_segment_count[meeting_id] = (meeting_segment_count[meeting_id]? || 0) + 1
      rescue
      end
    end
  end

  # Extract MeetingDecision objects from flagged transcript segments.
  @[Chronicle::Packs::Annotations::Behavior(name: "decision_extractor", on: ["object.created"], where: {"type" => "transcript_segment"}, creates: ["meeting_decision"])]
  def decision_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MeetingSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    seg_id = payload["id"]?.try(&.as_s?)
    return if seg_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless data["is_decision"]?.try(&.as_bool?) == true

    meeting_id = data["meeting_id"]?.try(&.as_s?)
    text = data["text"]?.try(&.as_s?) || ""
    speaker = data["speaker"]?.try(&.as_s?) || "Participant"

    begin
      decision = graph.add_object("meeting_decision", MeetingDecision.new(
        meeting_id: meeting_id || "",
        text: text,
        segment_id: seg_id,
        decided_by: [speaker],
        confidence: 0.80,
      ).to_json, actor: "meeting.decision_extractor")
      if meeting_id
        graph.add_relation(decision.id, meeting_id, "decision_in", actor: "meeting.decision_extractor")
      end
      graph.add_relation(decision.id, seg_id, "decision_from_segment", actor: "meeting.decision_extractor")
    rescue
    end
  end

  # Extract MeetingActionItems and create Core Tasks from transcript segments.
  @[Chronicle::Packs::Annotations::Behavior(name: "action_item_extractor", on: ["object.created"], where: {"type" => "transcript_segment"}, creates: ["meeting_action_item", "task"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream action_item_extractor task/action-item branches
  def action_item_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MeetingSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    seg_id = payload["id"]?.try(&.as_s?)
    return if seg_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless data["is_action_item"]?.try(&.as_bool?) == true
    return unless settings.auto_create_tasks_from_action_items?

    meeting_id = data["meeting_id"]?.try(&.as_s?)
    text = data["text"]?.try(&.as_s?) || ""
    speaker = data["speaker"]?.try(&.as_s?) || "Participant"

    action_text = text.size > 200 ? text[0, 200] : (text.empty? ? "Action item from meeting" : text)

    begin
      task = graph.add_object("task", {
        "title"       => JSON::Any.new("[Meeting] #{action_text[0, 60]}"),
        "description" => JSON::Any.new(action_text),
        "status"      => JSON::Any.new("candidate"),
        "priority"    => JSON::Any.new("medium"),
      }.to_json, actor: "meeting.action_item_extractor")

      action_item = graph.add_object("meeting_action_item", MeetingActionItem.new(
        meeting_id: meeting_id || "",
        text: action_text,
        owner_ref: speaker == "Participant" ? nil : speaker,
        segment_id: seg_id,
        task_id: task.id,
        status: ActionItemStatus::Open,
      ).to_json, actor: "meeting.action_item_extractor")

      if meeting_id
        graph.add_relation(action_item.id, meeting_id, "action_item_in", actor: "meeting.action_item_extractor")
      end
      graph.add_relation(action_item.id, seg_id, "action_item_from_segment", actor: "meeting.action_item_extractor")
      graph.add_relation(action_item.id, task.id, "action_creates_task", actor: "meeting.action_item_extractor")
    rescue
    end
  end

  # Generate a MeetingNote summary when a meeting is ingested.
  @[Chronicle::Packs::Annotations::Behavior(name: "meeting_summarizer", on: ["object.created"], where: {"type" => "meeting"}, creates: ["meeting_note"])]
  def meeting_summarizer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : MeetingSettings) : Nil
    return unless settings.auto_summarize_meeting?

    payload = JSON.parse(event.payload).as_h
    meeting_id = payload["id"]?.try(&.as_s?)
    return if meeting_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    title = data["title"]?.try(&.as_s?) || "Meeting"
    participants = data["participants"]?.try(&.as_a?) ? data["participants"].as_a.map(&.as_s) : [] of String

    summary_content =
      "# Meeting Summary: #{title}\n\n" \
      "**Date:** #{data["date"]?.try(&.as_s?) || "Unknown"}\n" \
      "**Platform:** #{data["platform"]?.try(&.as_s?) || "Unknown"}\n" \
      "**Participants:** #{participants.empty? ? "Unknown" : participants.join(", ")}\n\n" \
      "## Summary\n" \
      "Transcript is being processed. Decisions and action items will be extracted " \
      "from individual segments as they are created.\n\n" \
      "*(v0.1 mock summary — real LLM summarization in v0.2)*"

    begin
      note = graph.add_object("meeting_note", MeetingNote.new(
        meeting_id: meeting_id,
        content: summary_content,
        note_type: NoteType::Summary,
      ).to_json, actor: "meeting.meeting_summarizer")
      graph.add_relation(note.id, meeting_id, "note_for", actor: "meeting.meeting_summarizer")
    rescue
    end
  end
end

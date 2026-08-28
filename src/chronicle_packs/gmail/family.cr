require "json"
require "set"

module Chronicle::Packs::Gmail
  # Gmail-owned mapping into the service-neutral conversation family. Ported
  # from upstream packs/gmail/family.py.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module FamilyConstants
    MAPPER_VERSION = "gmail.conversation-mapper@0.1.0"
  end

  # Parse RFC-822-style address values ("Name <a@b>, c@d") into unique
  # {display_name, address} rows, mirroring Python email.utils.getaddresses.
  def self._addresses(*values : String?) : Array(Hash(String, String))
    rows = [] of Hash(String, String)
    seen = Set(String).new
    values.each do |value|
      (value || "").split(',').each do |part|
        part = part.strip
        next if part.empty?
        name = ""
        address = part
        if m = part.match(/^(.+?)\s*<([^>]+)>$/)
          name = m[1].strip
          address = m[2].strip
        end
        normalized = address.downcase
        next if normalized.empty? || seen.includes?(normalized)
        seen.add(normalized)
        rows << {"display_name" => name, "address" => normalized}
      end
    end
    rows
  end

  # Classify a message as notification/automated/human.
  def self._kind(metadata : Hash(String, JSON::Any), sender : String?) : {String, Bool}
    precedence = (metadata["precedence"]?.try(&.as_s?) || "").downcase
    auto_submitted = (metadata["auto_submitted"]?.try(&.as_s?) || "").downcase
    list_id = metadata["list_id"]?.try(&.as_s?)
    list_unsubscribe = metadata["list_unsubscribe"]?.try(&.as_s?)
    notification =
      !list_id.nil? || !list_unsubscribe.nil? ||
        precedence.in?({"bulk", "list", "junk"}) ||
        (!auto_submitted.empty? && auto_submitted != "no")
    automated =
      notification ||
        (!sender.nil? && ["no-reply", "noreply", "notifications@"].any? { |marker| sender.includes?(marker) })
    {(notification ? "notification" : (automated ? "automated" : "human")), notification}
  end

  # Map every current evidence revision in one run at one batch boundary.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream materialize_gmail_run_fn family mapping
  def self.materialize_gmail_run_fn(
    graph : Chronicle::GraphProjection,
    run : Chronicle::GraphObject,
    *,
    reader : Chronicle::GraphProjection,
    reprocess : Bool = false,
    offset : Int32 = 0,
    max_items : Int32 = 250,
  ) : {Hash(String, JSON::Any), Hash(String, JSON::Any)}
    run_data = JSON.parse(run.data).as_h
    evidence = reader.objects(type: "activity_evidence").select do |obj|
      ed = JSON.parse(obj.data).as_h
      ed["status"]?.try(&.as_s?) == "current" &&
        (ed["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any)["connector_run_id"]?.try(&.as_s?) == run.id
    end
    evidence.sort_by! { |obj| {(JSON.parse(obj.data)["provider_time"]?.try(&.as_s?) || ""), obj.id} }
    evidence = evidence.skip(offset).first(max_items).to_a

    state = {"model_requests" => JSON::Any.new(
      reader.objects(type: "conversation_interpretation_run").count { |obj|
        d = JSON.parse(obj.data).as_h
        (d["refs"]?.try(&.as_a) || [] of JSON::Any).any? { |ref| ref.as_s? == run.id } &&
          !d["semantic_request_id"]?.try(&.as_s?).nil?
      }
    )} of String => JSON::Any

    results = [] of Hash(String, JSON::Any)
    account_ref = (run_data["account_ref"]?.try(&.as_s?) || "").strip.downcase
    evidence.each do |item|
      ed = JSON.parse(item.data).as_h
      metadata = (ed["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any).dup
      provider_message_id = metadata["message_id"]?.try(&.as_s?) || ed["provider_item_id"]?.try(&.as_s?) || ""
      next if provider_message_id.empty?

      senders = _addresses(metadata["from"]?.try(&.as_s?))
      recipients = _addresses(metadata["to"]?.try(&.as_s?))
      cc = _addresses(metadata["cc"]?.try(&.as_s?))
      bcc = _addresses(metadata["bcc"]?.try(&.as_s?))
      sender = senders.empty? ? nil : senders.first["address"]

      participant_rows = [] of Hash(String, JSON::Any)
      { {"sender", senders}, {"recipient", recipients}, {"cc", cc}, {"bcc", bcc} }.each do |role, rows|
        rows.each do |row|
          participant_rows << {
            "display_name" => JSON::Any.new(row["display_name"]),
            "address"      => JSON::Any.new(row["address"]),
            "roles"        => JSON::Any.new([JSON::Any.new(role)]),
          }
        end
      end

      message_kind, notification = _kind(metadata, sender)
      labels = (metadata["labels"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
      body_offset = metadata["body_offset"]?.try(&.as_i?) || 0
      content = ed["normalized_content"]?.try(&.as_s?) || ""
      body_chars = metadata["body_chars"]?.try(&.as_i?) || Math.max(0, content.size - body_offset)
      body = content[body_offset, body_chars]

      hygiene = Communication.select_conversation_content(
        body,
        evidence_offset: body_offset,
        injection_flags: (metadata["injection_flags"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s),
        notification: notification,
      )

      result = Communication.materialize_conversation_message_fn(
        graph,
        reader: reader,
        source_surface_id: ed["source_surface_id"]?.try(&.as_s?) || "",
        service: "gmail",
        account_ref: account_ref,
        provider_thread_id: metadata["thread_id"]?.try(&.as_s?) || provider_message_id,
        provider_message_id: provider_message_id,
        provider_revision_ref: metadata["history_id"]?.try(&.as_s?) || ed["content_hash"]?.try(&.as_s?) || "unknown",
        evidence_id: item.id,
        evidence_revision_id: ed["revision_id"]?.try(&.as_s?) || "",
        subject: metadata["subject"]?.try(&.as_s?) || "",
        sender: sender,
        recipients: recipients.map { |row| row["address"] },
        cc: cc.map { |row| row["address"] },
        sent_at: ed["provider_time"]?.try(&.as_s?) || metadata["date"]?.try(&.as_s?),
        direction: begin
          all_recipients = Set(String).new
          {recipients, cc, bcc}.each { |rows| rows.each { |row| all_recipients << row["address"] } }
          if sender == account_ref
            "outbound"
          elsif all_recipients.includes?(account_ref)
            "inbound"
          else
            "unknown"
          end
        end,
        message_kind: message_kind,
        labels: labels,
        unread: labels.includes?("UNREAD"),
        internet_message_id: metadata["message_id_header"]?.try(&.as_s?),
        participants: participant_rows,
        hygiene: hygiene,
        refs: [run.id, item.id],
        reprocess: reprocess,
        state: state,
      )

      semantic_request_id = result.interpretation_run.try { |run_obj| JSON.parse(run_obj.data)["semantic_request_id"]?.try(&.as_s?) }
      results << {
        "thread_id"                 => JSON::Any.new(result.thread.id),
        "message_id"                => JSON::Any.new(result.message.id),
        "semantic_request_id"       => semantic_request_id ? JSON::Any.new(semantic_request_id) : JSON::Any.new(nil),
        "interpretation_run_status" => result.interpretation_run.try { |run_obj| JSON.parse(run_obj.data)["status"]?.try(&.as_s?) }.try { |value| JSON::Any.new(value) } || JSON::Any.new(nil),
      }
    end

    threads = {} of String => Chronicle::GraphObject
    reader.objects(type: "conversation_thread").each do |obj|
      threads[JSON.parse(obj.data)["thread_identity"]?.try(&.as_s?) || ""] = obj
    end
    participants = {} of String => Chronicle::GraphObject
    reader.objects(type: "conversation_participant").each do |obj|
      participants[JSON.parse(obj.data)["participant_identity"]?.try(&.as_s?) || ""] = obj
    end
    participant_by_id = {} of String => Chronicle::GraphObject
    participants.each_value { |obj| participant_by_id[obj.id] = obj }
    messages = {} of String => Chronicle::GraphObject
    reader.objects(type: "conversation_message").each do |obj|
      messages[JSON.parse(obj.data)["message_identity"]?.try(&.as_s?) || ""] = obj
    end
    message_by_id = {} of String => Chronicle::GraphObject
    messages.each_value { |obj| message_by_id[obj.id] = obj }

    rows = [] of Hash(String, JSON::Any)
    surface_id = run_data["source_surface_id"]?.try(&.as_s?) || ""
    threads.each_value do |thread|
      tdata = JSON.parse(thread.data).as_h
      next unless tdata["source_surface_id"]?.try(&.as_s?) == surface_id

      thread_messages = (tdata["message_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).compact_map { |mid| message_by_id[mid]? }
      latest = thread_messages.max_by? { |obj| {(JSON.parse(obj.data)["sent_at"]?.try(&.as_s?) || ""), obj.id} }
      participant_refs = (tdata["participant_ids"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).compact_map { |pid| participant_by_id[pid]?.try(&.id) }
      latest_data = latest ? JSON.parse(latest.data).as_h : {} of String => JSON::Any
      rows << {
        "thread_ref"           => JSON::Any.new(thread.id),
        "title"                => JSON::Any.new(tdata["subject"]?.try(&.as_s?) || ""),
        "participant_refs"     => JSON::Any.new(participant_refs.map { |id| JSON::Any.new(id) }),
        "last_message_at"      => tdata["last_message_at"]? || JSON::Any.new(nil),
        "unread_count"         => JSON::Any.new(tdata["unread_count"]?.try(&.as_i?) || 0),
        "message_count"        => JSON::Any.new(tdata["message_count"]?.try(&.as_i?) || 0),
        "latest_message_ref"   => latest ? JSON::Any.new(latest.id) : JSON::Any.new(nil),
        "latest_sender"        => latest_data["sender"]? || JSON::Any.new(nil),
        "preview"              => JSON::Any.new((latest_data["display_content"]?.try(&.as_s?) || "")[0, 240]),
        "interpretation_state" => JSON::Any.new(latest_data["interpretation_state"]?.try(&.as_s?) || "empty"),
        "status"               => JSON::Any.new(tdata["status"]?.try(&.as_s?) || "open"),
        "refs"                 => JSON::Any.new(((tdata["refs"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s))[0, 20].map { |id| JSON::Any.new(id) }),
      }
    end
    rows.sort_by! { |row| {(row["last_message_at"]?.try(&.as_s?) || ""), row["thread_ref"].as_s} }.reverse!

    native = {
      "threads"     => JSON::Any.new(rows.first(100).map { |row| JSON::Any.new(row) }),
      "total_count" => JSON::Any.new(rows.size),
    }
    semantic_requests = (state["model_requests"]?.try(&.as_i?) || 0)
    semantic_requests_created = results.count { |result_row|
      !result_row["semantic_request_id"]?.try(&.as_s?).nil? &&
        (result_row["interpretation_run_status"]?.try(&.as_s?) == "selected")
    }
    summary = {
      "messages"                  => JSON::Any.new(results.size),
      "threads"                   => JSON::Any.new(rows.size),
      "semantic_requests"         => JSON::Any.new(semantic_requests),
      "semantic_requests_created" => JSON::Any.new(semantic_requests_created),
      "mapper_version"            => JSON::Any.new(FamilyConstants::MAPPER_VERSION),
    }
    {native, summary}
  end
end

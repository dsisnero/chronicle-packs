require "json"
require "digest/sha256"

module Chronicle::Packs::Communication
  # Durable graph-state implementation of the conversation family contract.
  # Ported from upstream packs/communication/conversation.py.

  # Deterministic projector facet identifiers (nested so the DSL pack macro
  # doesn't treat them as typed constants).
  module FamilyConstants
    PROJECTOR_VERSION = "communication.family@0.1.0"
    LLM_FACETS        = %w(event_mention relation_mention)
    FOLLOWUP_CUE_RE   = /\b(please|can you|could you|would you|will you|need you to|action item|to[- ]?do|follow up|send me|let me know)\b/i
  end

  def self.stable_id(prefix : String, *parts) : String
    material = parts.map(&.to_s).join("\x1f")
    "#{prefix}_#{Digest::SHA256.hexdigest(material)}"
  end

  # Index an object type's rigid fields by a given identity field.
  def self._index_objects(reader : Chronicle::GraphProjection, object_type : String, field : String) : Hash(String, Chronicle::GraphObject)
    index = {} of String => Chronicle::GraphObject
    reader.objects(type: object_type).each do |obj|
      key = JSON.parse(obj.data)[field]?.try(&.as_s?)
      index[key] = obj if key
    end
    index
  end

  # Index entity_mention by its lowercased metadata["email"].
  def self._mention_index(reader : Chronicle::GraphProjection) : Hash(String, Chronicle::GraphObject)
    index = {} of String => Chronicle::GraphObject
    reader.objects(type: "entity_mention").each do |obj|
      email = (JSON.parse(obj.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["email"]?.try(&.as_s?) || ""
      index[email.downcase] = obj unless email.empty?
    end
    index
  end

  def self._patch(reader : Chronicle::GraphProjection, target : String, updates : Hash(String, JSON::Any)) : Nil
    return if updates.empty?
    obj = reader.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    updates.each { |key, value| data[key] = value }
    reader.patch_object(target, data.to_json)
  end

  def self._active_profile(reader : Chronicle::GraphProjection) : Chronicle::GraphObject?
    profiles = reader.objects(type: "extraction_profile").select do |obj|
      JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active"
    end
    profiles.max_by? { |obj| JSON.parse(obj.data)["version"]?.try(&.as_i?) || 0 }
  end

  def self._as_h(value : JSON::Any?) : Hash(String, JSON::Any)
    value.try(&.as_h) || {} of String => JSON::Any
  end

  def self._as_list(value : JSON::Any?) : Array(JSON::Any)
    value.try(&.as_a?) || [] of JSON::Any
  end

  def self._as_str_list(value : JSON::Any?) : Array(String)
    _as_list(value).map(&.as_s)
  end

  def self._any_list(values : Array(String)) : Array(JSON::Any)
    values.map { |value| JSON::Any.new(value) }
  end

  def self._any_hash_list(values : Array(Hash(String, JSON::Any))) : Array(JSON::Any)
    values.map { |value| JSON::Any.new(value) }
  end

  def self._any_counts(values : Hash(String, Int32)) : Hash(String, JSON::Any)
    values.transform_values { |value| JSON::Any.new(value) }
  end

  def self._as_i(value : JSON::Any?, default : Int32) : Int32
    value.try(&.as_i?) || default
  end

  # Normalized participant display name from an address (metadata use only).
  def self._normalized_name(address : String) : String
    address.split('@')[0].gsub('.', ' ').split(' ').map(&.capitalize).join(' ')
  end

  def self._participant_roles(roles : Array(String)) : Array(ParticipantRole)
    roles.map { |role| ParticipantRole.parse?(role) || ParticipantRole::Recipient }
  end

  # Result of one materialization pass.
  record MaterializeResult,
    thread : Chronicle::GraphObject,
    message : Chronicle::GraphObject,
    interpretation_run : Chronicle::GraphObject?,
    thread_created : Bool,
    message_created : Bool

  # Idempotently map one service message into strict family objects.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream materialize_conversation_message idempotency branches
  def self.materialize_conversation_message_fn(
    graph : Chronicle::GraphProjection,
    reader : Chronicle::GraphProjection,
    source_surface_id : String,
    service : String,
    account_ref : String,
    provider_thread_id : String,
    provider_message_id : String,
    provider_revision_ref : String,
    evidence_id : String,
    evidence_revision_id : String,
    subject : String,
    sender : String?,
    recipients : Array(String),
    cc : Array(String),
    sent_at : String?,
    direction : String,
    message_kind : String,
    labels : Array(String),
    unread : Bool,
    internet_message_id : String?,
    participants : Array(Hash(String, JSON::Any)),
    hygiene : HygieneResult,
    refs : Array(String),
    reprocess : Bool = false,
    state : Hash(String, JSON::Any)? = nil,
  ) : MaterializeResult
    state = state || {} of String => JSON::Any
    thread_by_identity = _index_objects(reader, "conversation_thread", "thread_identity")
    participant_by_identity = _index_objects(reader, "conversation_participant", "participant_identity")
    message_by_identity = _index_objects(reader, "conversation_message", "message_identity")
    run_by_identity = _index_objects(reader, "conversation_interpretation_run", "run_identity")
    mention_by_email = _mention_index(reader)

    thread_identity = stable_id("conversation_thread", service, account_ref, provider_thread_id)
    initial_thread = thread_by_identity[thread_identity]?
    thread_created = initial_thread.nil?
    thread = initial_thread
    thread_data = {} of String => JSON::Any
    if thread.nil?
      thread = graph.add_object("conversation_thread", ConversationThread.new(
        thread_identity: thread_identity,
        source_surface_id: source_surface_id,
        service: service,
        account_ref: account_ref,
        provider_thread_id: provider_thread_id,
        subject: subject,
        participant_ids: [] of String,
        message_ids: [] of String,
        status: ThreadStatus::Open,
        last_message_at: sent_at,
        unread_count: 0,
        message_count: 0,
        labels: labels.uniq,
        refs: refs.uniq,
        metadata: {"family_projector_version" => JSON::Any.new(FamilyConstants::PROJECTOR_VERSION)},
      ).to_json, actor: "communication")
      thread_data = JSON.parse(thread.data).as_h
    else
      thread_data = JSON.parse(thread.data).as_h
    end

    participant_ids = _as_str_list(thread_data["participant_ids"]?)
    unique_participants = {} of String => Hash(String, JSON::Any)
    participants.each do |participant|
      address = (participant["address"]?.try(&.as_s?) || "").strip.downcase
      next if address.empty?
      prior = unique_participants[address]? || {} of String => JSON::Any
      merged = prior.merge(participant)
      merged["address"] = JSON::Any.new(address)
      roles = (_as_str_list(prior["roles"]?) + _as_str_list(participant["roles"]?)).uniq!.sort
      merged["roles"] = JSON::Any.new(_any_list(roles))
      unique_participants[address] = merged
    end

    unique_participants.each do |address, participant|
      identity = stable_id("conversation_participant", thread_identity, address)
      existing = participant_by_identity[identity]?
      roles = _as_str_list(participant["roles"]?)
      refs_for = [evidence_id, *refs].uniq
      if existing.nil?
        mention = mention_by_email[address]?
        if mention.nil?
          display_name = (participant["display_name"]?.try(&.as_s?) || "").strip
          display_name = _normalized_name(address) if display_name.empty?
          mention = graph.add_object("entity_mention", JSON.build do |json|
            json.object do
              json.field "text", address
              json.field "source_id", evidence_id
              json.field "entity_id", nil
              json.field "entity_type_hint", "person"
              json.field "confidence", 0.95
              json.field "context_snippet", address
              json.field "extraction_method", "conversation_header"
              json.field "frame_id", nil
              json.field "metadata", {
                "email"                             => JSON::Any.new(address),
                "normalized_name"                   => JSON::Any.new(display_name),
                "conversation_participant_identity" => JSON::Any.new(identity),
              }
            end
          end, actor: "communication")
          mention_by_email[address] = mention
        end
        participant_obj = ConversationParticipant.new(
          participant_identity: identity,
          thread_id: thread.id,
          address: address,
          display_name: _as_s(participant["display_name"]?),
          roles: _participant_roles(roles),
          entity_mention_id: mention.id,
          refs: refs_for,
        )
        new_participant = graph.add_object("conversation_participant", participant_obj.to_json, actor: "communication")
        graph.add_relation(thread.id, new_participant.id, "conversation_has_participant", actor: "communication")
        graph.add_relation(new_participant.id, mention.id, "conversation_participant_mention", actor: "communication")
        participant_by_identity[identity] = new_participant
        participant_ids << new_participant.id unless participant_ids.includes?(new_participant.id)
      else
        existing_data = JSON.parse(existing.data).as_h
        merged_roles = (_as_str_list(existing_data["roles"]?) + roles).uniq!.sort
        merged_refs = (_as_str_list(existing_data["refs"]?) + refs_for).uniq
        _patch(graph, existing.id, {
          "roles" => JSON::Any.new(_any_list(merged_roles)),
          "refs"  => JSON::Any.new(_any_list(merged_refs)),
        })
        participant_ids << existing.id unless participant_ids.includes?(existing.id)
      end
    end

    message_identity = stable_id("conversation_message", service, account_ref, provider_message_id)
    initial_message = message_by_identity[message_identity]?
    message_created = initial_message.nil?
    message_payload = {
      "message_identity"       => JSON::Any.new(message_identity),
      "thread_id"              => JSON::Any.new(thread.id),
      "source_surface_id"      => JSON::Any.new(source_surface_id),
      "service"                => JSON::Any.new(service),
      "account_ref"            => JSON::Any.new(account_ref),
      "provider_message_id"    => JSON::Any.new(provider_message_id),
      "provider_revision_ref"  => JSON::Any.new(provider_revision_ref),
      "internet_message_id"    => internet_message_id ? JSON::Any.new(internet_message_id) : JSON::Any.new(nil),
      "sender"                 => sender ? JSON::Any.new(sender) : JSON::Any.new(nil),
      "recipients"             => JSON::Any.new(_any_list(recipients.uniq)),
      "cc"                     => JSON::Any.new(_any_list(cc.uniq)),
      "subject"                => JSON::Any.new(subject),
      "sent_at"                => sent_at ? JSON::Any.new(sent_at) : JSON::Any.new(nil),
      "direction"              => JSON::Any.new(direction),
      "message_kind"           => JSON::Any.new(message_kind),
      "labels"                 => JSON::Any.new(_any_list(labels.uniq)),
      "unread"                 => JSON::Any.new(unread),
      "display_content"        => JSON::Any.new(hygiene.display_content),
      "interpretation_content" => JSON::Any.new(hygiene.interpretation_content),
      "interpretation_state"   => JSON::Any.new(hygiene.interpretation_state),
      "suppression_counts"     => JSON::Any.new(_any_counts(hygiene.suppression_counts)),
      "injection_flags"        => JSON::Any.new(_any_list(hygiene.injection_flags)),
      "evidence_id"            => JSON::Any.new(evidence_id),
      "refs"                   => JSON::Any.new(_any_list([evidence_id, *refs].uniq)),
      "metadata"               => JSON::Any.new({"family_projector_version" => JSON::Any.new(FamilyConstants::PROJECTOR_VERSION), "hygiene_truncated" => JSON::Any.new(hygiene.truncated?)}),
    } of String => JSON::Any
    prior_unread = initial_message ? (JSON.parse(initial_message.data)["unread"]?.try(&.as_bool?) || false) : false
    message = initial_message
    if message.nil?
      message = graph.add_object("conversation_message", message_payload.to_json, actor: "communication")
      graph.add_relation(thread.id, message.id, "conversation_contains", actor: "communication")
      graph.add_relation(message.id, evidence_id, "conversation_message_from_evidence", actor: "communication")
      message_by_identity[message_identity] = message
    else
      current = JSON.parse(message.data).as_h
      changed = message_payload.select { |key, value| current[key]? != value }
      _patch(graph, message.id, changed)
    end

    message_ids = _as_str_list(thread_data["message_ids"]?)
    message_ids << message.id unless message_ids.includes?(message.id)
    unread_count = _as_i(thread_data["unread_count"]?, 0)
    if message_created && unread
      unread_count += 1
    elsif !message_created && prior_unread != unread
      unread_count += unread ? 1 : -1
    end
    thread_updates = {
      "subject"         => JSON::Any.new((_as_s(thread_data["subject"]?) || subject)),
      "participant_ids" => JSON::Any.new(_any_list(participant_ids)),
      "message_ids"     => JSON::Any.new(_any_list(message_ids)),
      "message_count"   => JSON::Any.new(message_ids.size),
      "unread_count"    => JSON::Any.new(Math.max(0, unread_count)),
      "labels"          => JSON::Any.new(_any_list((_as_str_list(thread_data["labels"]?) + labels).to_set.to_a.sort)),
      "refs"            => JSON::Any.new(_any_list((_as_str_list(thread_data["refs"]?) + refs).uniq)),
    } of String => JSON::Any
    prior_last_message = _as_s(thread_data["last_message_at"]?)
    if sent_at && (prior_last_message.empty? || sent_at >= prior_last_message)
      thread_updates["last_message_at"] = JSON::Any.new(sent_at)
    end
    _patch(graph, thread.id, thread_updates.select { |key, value| thread_data[key]? != value })

    profile = _active_profile(reader)
    profile_data = profile ? JSON.parse(profile.data).as_h : {} of String => JSON::Any
    extractor_map = _as_h(profile_data["extractor_by_facet"]?)
    requested_facets = FamilyConstants::LLM_FACETS.select { |facet| extractor_map.has_key?(facet) }.sort!
    extractor_refs = requested_facets.map { |facet| _as_s(extractor_map[facet]?) }.reject(&.empty?).uniq!.sort!

    selection_material = JSON.build do |json|
      json.array { hygiene.selections.each { |selection| json.raw(selection.to_json) } }
    end
    selection_id = stable_id("conversation_selection", evidence_revision_id, HygienePatterns::FILTER_VERSION, selection_material)
    selected_hash = Digest::SHA256.hexdigest(hygiene.interpretation_content)
    prior_runs = reader.objects(type: "conversation_interpretation_run").select do |obj|
      JSON.parse(obj.data)["message_id"]?.try(&.as_s?) == message.id
    end
    run_identity = stable_id(
      "conversation_interpretation",
      message.id,
      evidence_revision_id,
      selection_id,
      profile ? profile.id : "none",
      extractor_refs.join(","),
      reprocess ? prior_runs.size : "initial",
    )
    run = run_by_identity[run_identity]?
    unless run
      status = case hygiene.interpretation_state
               when "ready"      then "selected"
               when "held"       then "held"
               when "suppressed" then "suppressed"
               else                   "suppressed"
               end
      semantic_request = nil
      policy = reader.objects(type: "connector_operational_policy").find { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) == "active" }
      model_limit = policy ? _as_i(JSON.parse(policy.data)["max_provider_calls"]?, 10) : 10
      model_requests = _as_i(state["model_requests"]?, 0)
      if status == "selected" && !requested_facets.empty? && model_requests < model_limit
        semantic_request = _selection_request(graph, run_identity, evidence_id, evidence_revision_id, selection_id, hygiene.selections, requested_facets, message.id, refs)
        if semantic_request
          state["model_requests"] = JSON::Any.new(model_requests + 1)
        end
      elsif status == "selected"
        status = "deterministic_only"
      end

      run_payload = {
        "run_identity"                 => JSON::Any.new(run_identity),
        "message_id"                   => JSON::Any.new(message.id),
        "evidence_id"                  => JSON::Any.new(evidence_id),
        "evidence_revision_id"         => JSON::Any.new(evidence_revision_id),
        "selection_id"                 => JSON::Any.new(selection_id),
        "deterministic_filter_version" => JSON::Any.new(HygienePatterns::FILTER_VERSION),
        "family_projector_version"     => JSON::Any.new(FamilyConstants::PROJECTOR_VERSION),
        "extraction_profile_id"        => profile ? JSON::Any.new(profile.id) : JSON::Any.new(nil),
        "extractor_refs"               => JSON::Any.new(_any_list(extractor_refs)),
        "requested_facets"             => JSON::Any.new(_any_list(requested_facets)),
        "semantic_request_id"          => semantic_request ? JSON::Any.new(semantic_request.id) : JSON::Any.new(nil),
        "selections"                   => JSON::Any.new(_any_hash_list(hygiene.selections)),
        "selected_chars"               => JSON::Any.new(hygiene.interpretation_content.size),
        "selected_content_hash"        => JSON::Any.new(selected_hash),
        "status"                       => JSON::Any.new(status),
        "semantic_run_ids"             => JSON::Any.new([] of JSON::Any),
        "annotation_ids"               => JSON::Any.new([] of JSON::Any),
        "coverage"                     => JSON::Any.new({"selection_count" => JSON::Any.new(hygiene.selections.size), "model_upgrade" => JSON::Any.new(semantic_request ? "requested" : (requested_facets.empty? ? "not_configured" : "deferred_budget"))}),
        "suppression_counts"           => JSON::Any.new(_any_counts(hygiene.suppression_counts)),
        "reprocess_of"                 => (reprocess && !prior_runs.empty?) ? JSON::Any.new(prior_runs[-1].id) : JSON::Any.new(nil),
        "error"                        => JSON::Any.new(nil),
        "refs"                         => JSON::Any.new(_any_list([evidence_id, message.id, *refs].uniq)),
        "metadata"                     => JSON::Any.new({} of String => JSON::Any),
      } of String => JSON::Any
      run = graph.add_object("conversation_interpretation_run", run_payload.to_json, actor: "communication")
      run_by_identity[run_identity] = run
    end

    MaterializeResult.new(
      thread: thread,
      message: message,
      interpretation_run: run,
      thread_created: thread_created,
      message_created: message_created,
    )
  end

  def self._as_s(value : JSON::Any?) : String
    value.try(&.as_s?) || ""
  end

  # Issue (or degrade gracefully) the semantic extraction request.
  def self._selection_request(
    graph : Chronicle::GraphProjection,
    run_identity : String,
    evidence_id : String,
    evidence_revision_id : String,
    selection_id : String,
    selections : Array(Hash(String, JSON::Any)),
    requested_facets : Array(String),
    message_id : String,
    refs : Array(String),
  ) : Chronicle::GraphObject?
    payload = {
      "request_identity" => JSON::Any.new(stable_id("selection_extraction_request", run_identity)),
      "evidence_id"      => JSON::Any.new(evidence_id),
      "revision_id"      => JSON::Any.new(evidence_revision_id),
      "selection_id"     => JSON::Any.new(selection_id),
      "selections"       => JSON::Any.new(_any_hash_list(selections)),
      "requested_facets" => JSON::Any.new(_any_list(requested_facets)),
      "status"           => JSON::Any.new("proposed"),
      "run_ids"          => JSON::Any.new([] of JSON::Any),
      "annotation_ids"   => JSON::Any.new([] of JSON::Any),
      "error"            => JSON::Any.new(nil),
      "refs"             => JSON::Any.new(_any_list([evidence_id, message_id, *refs].uniq)),
      "metadata"         => JSON::Any.new({"conversation_message_id" => JSON::Any.new(message_id)}),
    } of String => JSON::Any
    begin
      graph.add_object("selection_extraction_request", payload.to_json, actor: "communication")
    rescue
      nil
    end
  end

  # Emit a typed event into the log (mirrors the port's emit seam).
  def self._emit_event(graph : Chronicle::GraphProjection, event_type : String, payload : Hash(String, JSON::Any), actor : String) : Chronicle::Event
    graph.emit(Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: graph.events.size.to_u64 + 1,
      id: "comm_evt_#{graph.events.size + 1}",
      type: event_type,
      actor: actor,
      caused_by: nil,
      payload: payload.to_json,
    ))
  end

  # Project the native conversation surface for one source surface.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream project_conversation_native row builder
  def self.project_conversation_native_fn(reader : Chronicle::GraphProjection, source_surface_id : String) : Hash(String, JSON::Any)
    threads = reader.objects(type: "conversation_thread").select do |obj|
      JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == source_surface_id
    end
    participants = {} of String => Chronicle::GraphObject
    reader.objects(type: "conversation_participant").each { |obj| participants[obj.id] = obj }
    mentions = {} of String => Chronicle::GraphObject
    reader.objects(type: "entity_mention").each { |obj| mentions[obj.id] = obj }
    messages = {} of String => Chronicle::GraphObject
    reader.objects(type: "conversation_message").each { |obj| messages[obj.id] = obj }

    rows = [] of Hash(String, JSON::Any)
    threads.each do |thread|
      thread_data = JSON.parse(thread.data).as_h
      participant_refs = [] of String
      attention_refs = [] of String
      _as_str_list(thread_data["participant_ids"]?).each do |participant_id|
        participant = participants[participant_id]?
        next if participant.nil?
        participant_data = JSON.parse(participant.data).as_h
        entity_ref = _as_s(participant_data["entity_id"]?)
        if entity_ref.empty? && (mention_id = participant_data["entity_mention_id"]?.try(&.as_s?))
          mention = mentions[mention_id]?
          entity_ref = _as_s(JSON.parse(mention.data)["entity_id"]?) if mention
        end
        participant_refs << (entity_ref.empty? ? participant.id : entity_ref)
        attention_refs << stable_id("person_email", _as_s(participant_data["address"]?))
      end
      thread_messages = _as_str_list(thread_data["message_ids"]?).compact_map { |mid| messages[mid]? }
      latest = thread_messages.max_by? do |obj|
        data = JSON.parse(obj.data)
        {_as_s(data["sent_at"]?), obj.id}
      end
      rows << {
        "thread_ref"           => JSON::Any.new(thread.id),
        "title"                => JSON::Any.new(_as_s(thread_data["subject"]?)),
        "participant_refs"     => JSON::Any.new(_any_list(participant_refs.uniq)),
        "attention_refs"       => JSON::Any.new(_any_list(attention_refs.uniq)),
        "last_message_at"      => thread_data["last_message_at"]?.try(&.as_s?).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
        "unread_count"         => JSON::Any.new(_as_i(thread_data["unread_count"]?, 0)),
        "message_count"        => JSON::Any.new(_as_i(thread_data["message_count"]?, 0)),
        "latest_message_ref"   => latest ? JSON::Any.new(latest.id) : JSON::Any.new(nil),
        "latest_sender"        => latest ? (JSON.parse(latest.data)["sender"]?.try(&.as_s?).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil)) : JSON::Any.new(nil),
        "preview"              => JSON::Any.new((latest ? _as_s(JSON.parse(latest.data)["display_content"]?) : "")[0, 240]),
        "interpretation_state" => JSON::Any.new(latest ? (_as_s(JSON.parse(latest.data)["interpretation_state"]?) || "empty") : "empty"),
        "status"               => JSON::Any.new(_as_s(thread_data["status"]?) || "open"),
        "refs"                 => JSON::Any.new(_any_list(_as_str_list(thread_data["refs"]?).first(20))),
      }
    end
    rows.sort! do |a, b|
      key_a = {_as_s(a["last_message_at"]?) || "", _as_s(a["thread_ref"]?)}
      key_b = {_as_s(b["last_message_at"]?) || "", _as_s(b["thread_ref"]?)}
      key_b <=> key_a
    end
    {"threads" => JSON::Any.new(_any_hash_list(rows.first(100))), "total_count" => JSON::Any.new(rows.size)}
  end

  # Mirror the generic extraction request outcome into the family run.
  @[Chronicle::Packs::Annotations::Behavior(name: "settle_conversation_interpretation", on: ["semantic.selection_extraction_settled"], creates: ["conversation_interpretation_run"])]
  def settle_conversation_interpretation(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    request_id = _as_s(payload["request_id"]?)
    status = payload["status"]?.try(&.as_s?)
    return unless status == "completed" || status == "failed"
    run = graph.objects(type: "conversation_interpretation_run").find do |obj|
      JSON.parse(obj.data)["semantic_request_id"]?.try(&.as_s?) == request_id
    end
    return if run.nil?
    _patch(graph, run.id, {
      "status"           => JSON::Any.new(status == "completed" ? "completed" : "failed"),
      "semantic_run_ids" => JSON::Any.new(_as_list(payload["run_ids"]?).map { |value| JSON::Any.new(value.as_s) }),
      "annotation_ids"   => JSON::Any.new(_as_list(payload["annotation_ids"]?).map { |value| JSON::Any.new(value.as_s) }),
      "error"            => payload["error"]?.try(&.as_s?).try { |v| JSON::Any.new(v) } || JSON::Any.new(nil),
    })
  end

  # A recorded outbound reply is strong salience evidence for thread and
  # counterparts. Emits a neutral semantic signal; the attention pack owns
  # validation and scoring.
  @[Chronicle::Packs::Annotations::Behavior(name: "conversation_outbound_attention_signal", on: ["object.created"], where: {"type" => "conversation_message", "data.direction" => "outbound"}, creates: ["attention_observation"])]
  def conversation_outbound_attention_signal(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    wrapper = JSON.parse(event.payload).as_h
    data = _as_h(wrapper["data"]?)
    message_id = _as_s(wrapper["id"]?)
    message_identity = (_as_s(data["message_identity"]?).empty? ? message_id : _as_s(data["message_identity"]?))
    thread_id = _as_s(data["thread_id"]?)
    return if message_id.empty? || thread_id.empty?

    counterpart_addresses = Set(String).new
    (_as_str_list(data["recipients"]?) + _as_str_list(data["cc"]?)).each do |address|
      address = address.strip.downcase
      counterpart_addresses << address unless address.empty?
    end

    observations = [] of Hash(String, JSON::Any)
    observations << {
      "observation_id" => JSON::Any.new(stable_id("attention_observation", "outbound_reply", message_identity, thread_id)),
      "subject_ref"    => JSON::Any.new(thread_id),
      "subject_kind"   => JSON::Any.new("conversation_thread"),
      "signal_type"    => JSON::Any.new("replied"),
      "strength_milli" => JSON::Any.new(1_000),
      "context_key"    => JSON::Any.new("communication"),
      "source"         => JSON::Any.new("connector"),
      "evidence_refs"  => JSON::Any.new([JSON::Any.new(_as_s(data["evidence_id"]?))]),
      "metadata"       => JSON::Any.new({"message_id" => JSON::Any.new(message_id), "derivation" => JSON::Any.new("outbound_message")}),
    }
    counterpart_addresses.to_a.sort.each do |address|
      person_ref = stable_id("person_email", address)
      observations << {
        "observation_id" => JSON::Any.new(stable_id("attention_observation", "outbound_reply", message_identity, person_ref)),
        "subject_ref"    => JSON::Any.new(person_ref),
        "subject_kind"   => JSON::Any.new("person"),
        "signal_type"    => JSON::Any.new("replied"),
        "strength_milli" => JSON::Any.new(800),
        "context_key"    => JSON::Any.new("communication"),
        "source"         => JSON::Any.new("connector"),
        "evidence_refs"  => JSON::Any.new([JSON::Any.new(_as_s(data["evidence_id"]?))]),
        "metadata"       => JSON::Any.new({"message_id" => JSON::Any.new(message_id), "derivation" => JSON::Any.new("outbound_counterpart")}),
      }
    end
    _emit_event(graph, "attention.signal_observed", {"producer" => JSON::Any.new("communication"), "observations" => JSON::Any.new(observations.map { |observation| JSON::Any.new(observation) })}, "communication")
  end

  # Project one reviewable task only from an explicit exact-span request.
  @[Chronicle::Packs::Annotations::Behavior(name: "project_conversation_followup_candidate", on: ["object.created"], where: {"type" => "semantic_annotation", "data.facet" => "relation_mention", "data.status" => "active"}, creates: ["task_candidate"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream task-candidate guards
  def project_conversation_followup_candidate(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CommunicationSettings) : Nil
    wrapper = JSON.parse(event.payload).as_h
    data = _as_h(wrapper["data"]?)
    body = _as_h(data["body"]?)
    selector = _as_h(data["selector"]?)
    exact = (_as_s(selector["exact"]?).empty? ? _as_s(body["text"]?) : _as_s(selector["exact"]?)).strip
    return if exact.empty? || !FamilyConstants::FOLLOWUP_CUE_RE.matches?(exact)
    evidence_id = _as_s(data["evidence_id"]?)
    return if evidence_id.empty?
    messages = graph.objects(type: "conversation_message").select do |obj|
      JSON.parse(obj.data)["evidence_id"]?.try(&.as_s?) == evidence_id
    end
    return if messages.empty?
    message = messages[-1]
    message_data = JSON.parse(message.data).as_h
    if _as_s(message_data["direction"]?) != "inbound" || _as_s(message_data["interpretation_state"]?) != "ready" || !_as_list(message_data["injection_flags"]?).empty?
      return
    end
    annotation_id = _as_s(wrapper["id"]?)
    if graph.objects(type: "task_candidate").any? { |obj| (JSON.parse(obj.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["annotation_id"]?.try(&.as_s?) == annotation_id }
      return
    end
    evidence = graph.get_object(evidence_id)
    return if evidence.nil?
    title = exact[0, 120].rstrip
    confidence = data["confidence"]?.try(&.as_f?) || 0.5
    candidate_payload = {
      "candidate_identity"   => JSON::Any.new(stable_id("task_candidate", annotation_id)),
      "text"                 => JSON::Any.new(exact),
      "confidence"           => JSON::Any.new(confidence),
      "evidence_id"          => JSON::Any.new(evidence_id),
      "evidence_identity"    => _as_s(data["evidence_identity"]?).empty? ? JSON::Any.new(nil) : JSON::Any.new(_as_s(data["evidence_identity"]?)),
      "revision_id"          => _as_s(data["revision_id"]?).empty? ? JSON::Any.new(nil) : JSON::Any.new(_as_s(data["revision_id"]?)),
      "extraction_record_id" => _as_s(data["run_id"]?).empty? ? JSON::Any.new(nil) : JSON::Any.new(_as_s(data["run_id"]?)),
      "extractor_id"         => _as_s(data["extractor_id"]?).empty? ? JSON::Any.new(nil) : JSON::Any.new(_as_s(data["extractor_id"]?)),
      "extractor_version"    => _as_s(data["extractor_version"]?).empty? ? JSON::Any.new(nil) : JSON::Any.new(_as_s(data["extractor_version"]?)),
      "extraction_config_id" => _as_s(data["config_hash"]?).empty? ? JSON::Any.new(nil) : JSON::Any.new(_as_s(data["config_hash"]?)),
      "status"               => JSON::Any.new("candidate"),
      "invalidation_reason"  => JSON::Any.new(nil),
      "metadata"             => JSON::Any.new({"projector" => JSON::Any.new("communication.followup"), "annotation_id" => JSON::Any.new(annotation_id), "conversation_message_id" => JSON::Any.new(message.id), "owner_ref" => JSON::Any.new("owner"), "requires_review" => JSON::Any.new(true)}),
      "title"                => JSON::Any.new(title),
      "description"          => JSON::Any.new(exact),
    } of String => JSON::Any
    candidate = graph.add_object("task_candidate", candidate_payload.to_json, actor: "communication.followup")
    graph.add_relation(candidate.id, evidence_id, "extracted_from", actor: "communication.followup")
    graph.add_relation(candidate.id, annotation_id, "projected_from_annotation", actor: "communication.followup")
  end
end

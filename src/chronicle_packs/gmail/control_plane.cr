require "json"
require "set"

module Chronicle::Packs::Gmail
  # Explicit Gmail -> connector-control adapter. Ported from upstream
  # packs/gmail/control_plane.py.
  #
  # Gmail owns provider/cursor semantics. This module is the only place that
  # maps those semantics into the service-neutral control plane; neither the
  # neutral pack nor BabyAGI parses a Gmail run.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module ControlPlaneConstants
    STATE_MAP = {
      "proposed"  => "queued",
      "running"   => "running",
      "completed" => "succeeded",
      "partial"   => "partial",
      "failed"    => "failed",
    }
  end

  def self._objects(reader : Chronicle::GraphProjection, object_type : String) : Array(Chronicle::GraphObject)
    reader.objects(type: object_type)
  end

  def self._cursor(reader : Chronicle::GraphProjection, source_surface_id : String) : Chronicle::GraphObject?
    _objects(reader, "backfill_cursor").find { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == source_surface_id }
  end

  def self._evidence_for_run(reader : Chronicle::GraphProjection, run_id : String) : Array(Chronicle::GraphObject)
    _objects(reader, "activity_evidence").select do |obj|
      (JSON.parse(obj.data)["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any)["connector_run_id"]?.try(&.as_s?) == run_id
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _learning_counts resolution buckets
  def self._learning_counts(reader : Chronicle::GraphProjection, run : Chronicle::GraphObject) : Hash(String, JSON::Any)
    evidence = _evidence_for_run(reader, run.id)
    evidence_ids = evidence.map(&.id).to_set
    created = evidence.count { |obj| (JSON.parse(obj.data)["revision_number"]?.try(&.as_i?) || 0) == 1 }
    updated = evidence.count { |obj| (JSON.parse(obj.data)["revision_number"]?.try(&.as_i?) || 0) > 1 }

    annotations = _objects(reader, "semantic_annotation").select do |obj|
      d = JSON.parse(obj.data)
      d["evidence_id"]?.try(&.as_s?).try { |id| evidence_ids.includes?(id) } == true &&
        d["status"]?.try(&.as_s?) == "active"
    end
    facets = {} of String => Int64
    annotations.each do |obj|
      facet = JSON.parse(obj.data)["facet"]?.try(&.as_s?) || "unknown"
      facets[facet] = (facets[facet]? || 0_i64) + 1_i64
    end

    candidates = {} of String => Hash(String, Int64)
    {"preference_candidate", "task_candidate", "profile_candidate", "skill_candidate", "eval_candidate"}.each do |object_type|
      rows = _objects(reader, object_type).select do |obj|
        JSON.parse(obj.data)["evidence_id"]?.try(&.as_s?).try { |id| evidence_ids.includes?(id) } == true
      end
      next if rows.empty?
      outcomes = {} of String => Int64
      rows.each do |obj|
        status = JSON.parse(obj.data)["status"]?.try(&.as_s?) || "candidate"
        bucket =
          if status.in?({"promoted", "accepted"})
            "promoted"
          elsif status.in?({"rejected", "demoted"})
            "rejected"
          elsif status.in?({"invalidated", "suppressed"})
            "suppressed"
          else
            "proposed"
          end
        outcomes[bucket] = (outcomes[bucket]? || 0_i64) + 1_i64
      end
      candidates[object_type] = outcomes
    end

    failures = _objects(reader, "ingestion_failure").select do |obj|
      (JSON.parse(obj.data)["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["run_id"]?.try(&.as_s?) == run.id
    end
    refs = [run.id] + evidence.map(&.id) + annotations.map(&.id)
    run_data = JSON.parse(run.data).as_h
    {
      "evidence" => JSON::Any.new({
        "created" => JSON::Any.new(created),
        "updated" => JSON::Any.new(updated),
        "deleted" => JSON::Any.new(run_data["tombstones_recorded"]?.try(&.as_i?) || 0),
      }),
      "annotation_coverage" => JSON::Any.new(facets.map { |facet, count| {facet, JSON::Any.new(count)} }.to_h),
      "resolutions"         => JSON::Any.new({} of String => JSON::Any),
      "candidates"          => JSON::Any.new(candidates.map { |candidate, buckets| {candidate, JSON::Any.new(buckets.map { |bucket, count| {bucket, JSON::Any.new(count)} }.to_h)} }.to_h),
      "failures"            => JSON::Any.new(failures.size),
      "exceptions"          => JSON::Any.new(failures.map do |obj|
        d = JSON.parse(obj.data)
        JSON::Any.new({
          "object_id" => JSON::Any.new(obj.id),
          "code"      => JSON::Any.new(d["error_code"]?.try(&.as_s?) || "unknown"),
          "stage"     => JSON::Any.new(d["stage"]?.try(&.as_s?) || "unknown"),
        })
      end),
      "refs" => JSON::Any.new(refs.map { |id| JSON::Any.new(id) }),
    }
  end

  # Whether every imported evidence revision has extraction coverage. The
  # adapter uses this batch boundary instead of refreshing its aggregate once
  # per annotation. It is provider-neutral in shape but Gmail-owned in run
  # semantics: ``messages_imported`` is authoritative for this service.
  def self.gmail_learning_settled(reader : Chronicle::GraphProjection, run : Chronicle::GraphObject) : Bool
    expected = JSON.parse(run.data)["messages_imported"]?.try(&.as_i?) || 0
    return true if expected == 0
    evidence = _evidence_for_run(reader, run.id)
    return false if evidence.size < expected
    evidence_ids = evidence.map(&.id).to_set
    covered = Set(String).new
    _objects(reader, "extraction_coverage").each do |obj|
      id = JSON.parse(obj.data)["evidence_id"]?.try(&.as_s?) || ""
      covered.add(id) if evidence_ids.includes?(id)
    end
    _objects(reader, "conversation_interpretation_run").each do |obj|
      d = JSON.parse(obj.data)
      id = d["evidence_id"]?.try(&.as_s?) || ""
      if evidence_ids.includes?(id) && d["status"]?.try(&.as_s?).in?({"deterministic_only", "completed", "held", "suppressed"})
        covered.add(id)
      end
    end
    evidence_ids.all? { |id| covered.includes?(id) }
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream adapt_gmail_run_fn binding/observation/delta/native branches
  def self.adapt_gmail_run_fn(
    graph : Chronicle::GraphProjection,
    run : Chronicle::GraphObject,
    *,
    source_event_id : String?,
    attempt : Bool,
    reader : Chronicle::GraphProjection,
    native_data : Hash(String, JSON::Any)? = nil,
    learning_settled_override : Bool? = nil,
  ) : Nil
    data = JSON.parse(run.data).as_h
    source_surface_id = data["source_surface_id"]?.try(&.as_s?) || ""
    account_ref = data["account_ref"]?.try(&.as_s?) || ""
    route = (data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["route"]?.try(&.as_s?) || "composio"
    status = data["status"]?.try(&.as_s?) || "proposed"
    state = ControlPlaneConstants::STATE_MAP[status]? || "failed"
    mode = data["mode"]?.try(&.as_s?) || "backfill"

    cursor = _cursor(reader, source_surface_id)
    cursor_data = cursor ? JSON.parse(cursor.data).as_h : {} of String => JSON::Any
    has_position =
      !cursor_data["watermark_ref"]?.try(&.as_s?).nil? ||
        !cursor_data["newest_ingested_ref"]?.try(&.as_s?).nil? ||
        !cursor_data["oldest_ingested_ref"]?.try(&.as_s?).nil?
    position_kind =
      if !cursor_data["watermark_ref"]?.try(&.as_s?).nil?
        "history"
      elsif has_position
        "message"
      else
        nil
      end
    coverage =
      if mode == "poll" && state == "succeeded"
        "current"
      elsif state.in?({"succeeded", "partial"})
        "bounded"
      else
        "unknown"
      end
    maintenance_mode = "manual"
    manual_refresh = state.in?({"succeeded", "partial", "failed"})

    ConnectorControl.record_connector_binding_fn(
      graph,
      source_surface_id: source_surface_id,
      service: "gmail",
      account_ref: account_ref,
      family: "conversation",
      active_route: route,
      routes: [route],
      domain_run_type: "gmail_sync_run",
      maintenance_mode: maintenance_mode,
      manual_refresh_available: manual_refresh,
      metadata: {"adapter" => JSON::Any.new("gmail.control_plane@0.1.0")},
    )
    phase = {
      "queued"    => "queued",
      "running"   => mode == "poll" ? "checking_updates" : "acquiring",
      "succeeded" => "served",
      "partial"   => "sample_ready",
      "failed"    => "failed",
    }[state]

    ConnectorControl.record_connector_run_observation_fn(
      graph,
      domain_run_id: run.id,
      source_surface_id: source_surface_id,
      service: "gmail",
      account_ref: account_ref,
      family: "conversation",
      route: route,
      state: state,
      phase: phase,
      mode: mode,
      source_event_id: source_event_id,
      attempt: attempt,
      bounds: {
        "max_items" => JSON::Any.new(data["max_messages"]?.try(&.as_i?) || 0),
        "max_pages" => JSON::Any.new(data["max_pages"]?.try(&.as_i?) || 0),
        "page_size" => JSON::Any.new(data["page_size"]?.try(&.as_i?) || 0),
      },
      counts: {
        "imported"   => (data["messages_imported"]?.try(&.as_i?) || 0).to_i64,
        "pages"      => (data["pages_completed"]?.try(&.as_i?) || 0).to_i64,
        "deleted"    => (data["deleted_message_ids"]?.try(&.as_a) || [] of JSON::Any).size.to_i64,
        "tombstones" => (data["tombstones_recorded"]?.try(&.as_i?) || 0).to_i64,
      },
      cursor: {
        "position_kind" => position_kind ? JSON::Any.new(position_kind) : JSON::Any.new(nil),
        "has_position"  => JSON::Any.new(has_position),
        "advanced"      => JSON::Any.new(state.in?({"succeeded", "partial"}) && has_position),
        "coverage"      => JSON::Any.new(coverage),
      },
      maintenance_mode: maintenance_mode,
      manual_refresh_available: manual_refresh,
      next_sync_available: state.in?({"succeeded", "partial"}),
      error_code: data["error_code"]?.try(&.as_s?),
      error: data["error"]?.try(&.as_s?),
      metadata: {"adapter" => JSON::Any.new("gmail.control_plane@0.1.0")},
    )

    learning = _learning_counts(reader, run)
    settled =
      if learning_settled_override.nil?
        gmail_learning_settled(reader, run)
      else
        learning_settled_override
      end
    delta_status = {
      "queued"    => "collecting",
      "running"   => "collecting",
      "succeeded" => "complete",
      "partial"   => "partial",
      "failed"    => "failed",
    }[state]
    if state.in?({"succeeded", "partial"}) && !settled
      delta_status = "collecting"
    end
    ConnectorControl.record_connector_learning_delta_fn(
      graph,
      domain_run_id: run.id,
      source_surface_id: source_surface_id,
      service: "gmail",
      family: "conversation",
      status: delta_status,
      evidence: learning["evidence"].as_h.map { |key, count| {key, count.as_i.to_i64} }.to_h,
      annotation_coverage: learning["annotation_coverage"].as_h.map { |key, count| {key, count.as_i.to_i64} }.to_h,
      resolutions: {} of String => Int64,
      candidates: learning["candidates"].as_h.map { |candidate, buckets| {candidate, buckets.as_h.map { |bucket, count| {bucket, count.as_i.to_i64} }.to_h} }.to_h,
      failures: learning["failures"].as_i,
      exceptions: learning["exceptions"].as_a.map(&.as_h),
      refs: learning["refs"].as_a.map(&.as_s),
      metadata: {"adapter" => JSON::Any.new("gmail.control_plane@0.1.0")},
    )

    # Push 1 proves the native family contract and honest partial/empty states.
    # Push 3 fills threads/messages from the communication family.
    native_ready = native_data ? ((native_data["total_count"]?.try(&.as_i?) || 0) > 0) : false
    native_state =
      if state == "failed"
        "failed"
      elsif (data["messages_imported"]?.try(&.as_i?) || 0) == 0
        "empty"
      elsif native_ready
        "ready"
      else
        "partial"
      end
    ConnectorControl.record_connector_native_view_fn(
      graph,
      source_surface_id: source_surface_id,
      service: "gmail",
      family: "conversation",
      state: native_state,
      data: native_data || {"threads" => JSON::Any.new([] of JSON::Any), "total_count" => JSON::Any.new(0)},
      refs: [run.id],
      service_extensions: {
        "gmail" => JSON::Any.new({
          "messages_imported"      => JSON::Any.new(data["messages_imported"]?.try(&.as_i?) || 0),
          "thread_materialization" => JSON::Any.new(native_data.nil? ? "pending" : "ready"),
          "thread_labels"          => JSON::Any.new(
            _objects(reader, "conversation_thread").select { |obj| JSON.parse(obj.data)["source_surface_id"]?.try(&.as_s?) == source_surface_id }.map { |obj|
              {obj.id, JSON::Any.new(JSON.parse(obj.data)["labels"]?.try(&.as_a) || [] of JSON::Any)}
            }.to_h
          ),
        }),
      },
      error: data["error"]?.try(&.as_s?),
    )
  end

  def self.gmail_run_id_for_object(reader : Chronicle::GraphProjection, object_type : String, data : Hash(String, JSON::Any)) : String?
    if object_type == "gmail_sync_run"
      return data["_object_id"]?.try(&.as_s?)
    end
    if object_type == "activity_evidence"
      return (data["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any)["connector_run_id"]?.try(&.as_s?)
    end
    evidence_id = data["evidence_id"]?.try(&.as_s?) || ""
    if !evidence_id.empty?
      evidence = _objects(reader, "activity_evidence").find { |obj| obj.id == evidence_id }
      if evidence
        return (JSON.parse(evidence.data)["normalized_metadata"]?.try(&.as_h) || {} of String => JSON::Any)["connector_run_id"]?.try(&.as_s?)
      end
    end
    if object_type == "ingestion_failure"
      return (data["metadata"]?.try(&.as_h) || {} of String => JSON::Any)["run_id"]?.try(&.as_s?)
    end
    nil
  end

  # Backfill neutral adapters for stores created before connector_control.
  # This migration remains Gmail-owned: BabyAGI calls one service helper and
  # never interprets a Gmail field.
  def self.ensure_gmail_control_plane_fn(graph : Chronicle::GraphProjection) : Int32
    event_refs = {} of String => Array(String)
    graph.events.each do |event|
      payload = JSON.parse(event.payload).as_h
      object_id = ""
      if event.type == "object.created"
        object_id = payload["id"]?.try(&.as_s?) || ""
      elsif event.type == "patch.applied"
        object_id = payload["target"]?.try(&.as_s?) || ""
      end
      if !object_id.empty?
        refs = event_refs[object_id]? || [] of String
        refs << event.id
        event_refs[object_id] = refs
      end
    end
    runs = graph.objects(type: "gmail_sync_run")
    runs.each do |run|
      refs = event_refs[run.id]? || [] of String
      observed = graph.objects(type: "connector_run_observation").find { |obj| JSON.parse(obj.data)["domain_run_id"]?.try(&.as_s?) == run.id }
      adapt_gmail_run_fn(
        graph,
        run,
        source_event_id: refs.last?,
        attempt: observed.nil?,
        reader: graph,
      )
    end
    runs.size
  end
end

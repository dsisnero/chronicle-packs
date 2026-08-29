require "json"
require "time"

module Chronicle::Packs::Evolution
  # Evolution Pack behaviors. Ported from upstream packs/evolution/behaviors.py.
  #
  # Four reactive pieces of the loop live as behaviors; everything that must
  # run outside a frame (trials, adoption phase two) lives in trial.py and
  # adopt.py and is invoked by the host. Everything here no-ops when
  # EvolutionSettings.enabled is False (the shipped default).
  #
  # 1. gap_detector        — repeated capability failures open a gap, with
  #                          deterministic taint inheritance.
  # 2. proposal_gatekeeper — mod_proposal.created runs the stage-2 static
  #                          gates (after the taint check: suspended
  #                          proposals are never gated).
  # 3. promotion_recorder  — a post-adoption reaction point, on the
  #                          promote.applied marker: flips mod_promotion
  #                          from loading to active and the proposal to
  #                          promoted.
  # 4. watch_monitor       — post-adoption self-noticing: scans the event
  #                          log for behavior.failed events attributable to
  #                          an adopted pack within its watch window.

  def self._evt_ord(evt_id : String?) : Int32?
    return nil if evt_id.nil? || evt_id.empty?
    idx = evt_id.rindex('_')
    return nil if idx.nil?
    tail = evt_id[idx + 1..]
    return nil unless tail.each_char.all?(&.ascii_number?)
    tail.to_i?
  end

  def self._beh_now : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%S%:z")
  end

  # Merge a top-level hash patch onto an object (chronicle's patch_object
  # replaces data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any), actor : String) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json, actor: actor)
  end

  # Open a tool_failure gap after N failures of the same capability.
  #
  # Taint inheritance is deterministic: the gap's injection_flags are the
  # union of flags on the evidence results, computed here, never trusted
  # from any model output.
  @[Chronicle::Packs::Annotations::Behavior(name: "gap_detector", on: ["object.created"], where: {"type" => "capability_result"}, creates: ["capability_gap"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream gap_detector
  def gap_detector(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : EvolutionSettings) : Nil
    return unless settings.enabled?
    payload = JSON.parse(event.payload)
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return unless data["success"]?.try(&.raw) != true

    capability = "#{data["provider_name"]?.try(&.as_s?) || ""}.#{data["capability_name"]?.try(&.as_s?) || ""}"

    failures = graph.objects(type: "capability_result").select do |res_obj|
      odata = JSON.parse(res_obj.data)
      odata["success"]?.try(&.raw) != true &&
        "#{odata["provider_name"]?.try(&.as_s?) || ""}.#{odata["capability_name"]?.try(&.as_s?) || ""}" == capability
    end
    return if failures.size < settings.gap_failure_threshold

    # One open gap per failing capability.
    graph.objects(type: "capability_gap").each do |gap|
      gdata = JSON.parse(gap.data)
      if gdata["status"]?.try(&.as_s?) == "open"
        if meta = gdata["metadata"]?.try(&.as_h)
          if meta["capability"]?.try(&.as_s?) == capability
            return
          end
        end
      end
    end

    inherited = failures.flat_map { |res_obj| JSON.parse(res_obj.data)["injection_flags"]?.try(&.as_a) || [] of JSON::Any }.map(&.as_s).to_set.to_a.sort
    graph.add_object("capability_gap", {
      "kind"            => JSON::Any.new("tool_failure"),
      "description"     => JSON::Any.new("#{capability} failed #{failures.size} times"),
      "evidence_refs"   => JSON::Any.new(failures.map { |res_obj| JSON::Any.new(res_obj.id) }),
      "injection_flags" => JSON::Any.new(inherited.map { |flag| JSON::Any.new(flag) }),
      "status"          => JSON::Any.new("open"),
      "metadata"        => JSON::Any.new({"capability" => JSON::Any.new(capability)}),
    }.to_json, actor: "evolution.gap_detector")
  end

  # Run the static gates on every new proposal.
  #
  # Taint first: a proposal whose own flags, or whose gap's inherited flags,
  # are non-empty is suspended before any gate runs, and stays suspended
  # until the owner explicitly clears it.
  #
  @[Chronicle::Packs::Annotations::Behavior(name: "proposal_gatekeeper", on: ["object.created"], where: {"type" => "mod_proposal"}, creates: ["gate_result"])]
  def proposal_gatekeeper(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EvolutionSettings) : Nil
    return unless settings.enabled?
    payload = JSON.parse(event.payload)
    proposal_id = payload["id"]?.try(&.as_s?)
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    return if proposal_id.nil? || data["status"]?.try(&.as_s?) != "drafted"

    flags = (data["injection_flags"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
    gap_id = data["gap_id"]?.try(&.as_s?) || ""
    if !gap_id.empty?
      gap = graph.get_object(gap_id)
      if gap
        flags += (JSON.parse(gap.data)["injection_flags"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
      end
    end
    if !flags.empty?
      _merge_patch(graph, proposal_id, {
        "status"          => JSON::Any.new("suspended"),
        "status_note"     => JSON::Any.new("tainted lineage: #{flags.to_set.to_a.sort.join(", ")}"),
        "injection_flags" => JSON::Any.new(flags.to_set.to_a.sort.map { |flag| JSON::Any.new(flag) }),
      }, "evolution.proposal_gatekeeper")
      return
    end

    _run_crystal_static_gatekeeper(graph, proposal_id, settings)
  end

  private def self._run_crystal_static_gatekeeper(graph : Chronicle::GraphProjection, proposal_id : String, settings : EvolutionSettings) : Nil
    proposal = graph.get_object(proposal_id)
    return if proposal.nil?
    files = Materialize.proposal_files(graph, proposal)
    proposal_data = JSON.parse(proposal.data)
    config = Analysis::CrystalStaticGateConfig.new(
      allowed_files: settings.crystal_allowed_files,
      allowed_requires: settings.crystal_require_allow,
      reserved_paths: settings.reserved_paths,
      reserved_namespaces: settings.reserved_namespaces,
      never_callable: ToolGateway::Untrusted::NEVER_LLM_CALLABLE.to_a,
      max_total_source_bytes: settings.max_total_source_bytes,
      max_file_source_bytes: settings.max_file_bytes,
      expected_bundle_hash: proposal_data["bundle_hash"]?.try(&.as_s?) || "",
    )
    Analysis.crystal_static_gate_results(files, config).each do |gate, violations|
      if violations.empty?
        _record_static_gate(graph, proposal_id, gate, "pass", "")
        next
      end

      details = violations.join("; ")
      _record_static_gate(graph, proposal_id, gate, "fail", details)
      _merge_patch(graph, proposal_id, {
        "status"      => JSON::Any.new("rejected"),
        "status_note" => JSON::Any.new("#{gate}: #{violations.first? || gate}"),
      }, "evolution.proposal_gatekeeper")
      return
    end

    injection_flags = Set(String).new
    files.each_value do |source|
      ToolGateway::Untrusted.scan_for_injection(source).each { |flag| injection_flags << flag }
    end
    flags = injection_flags.to_a.sort
    unless flags.empty?
      _record_static_gate(graph, proposal_id, "static:injection", "suspended", flags.join(", "))
      _merge_patch(graph, proposal_id, {
        "status"          => JSON::Any.new("suspended"),
        "status_note"     => JSON::Any.new("injection patterns in source: #{flags.join(", ")}"),
        "injection_flags" => JSON::Any.new(flags.map { |flag| JSON::Any.new(flag) }),
      }, "evolution.proposal_gatekeeper")
      return
    end

    _record_static_gate(graph, proposal_id, "static:injection", "pass", "")

    _merge_patch(graph, proposal_id, {
      "status"      => JSON::Any.new("gated"),
      "status_note" => JSON::Any.new(""),
    }, "evolution.proposal_gatekeeper")
  end

  private def self._record_static_gate(graph : Chronicle::GraphProjection, proposal_id : String, gate : String, verdict : String, details : String) : Nil
    result = graph.add_object("gate_result", {
      "proposal_id" => JSON::Any.new(proposal_id),
      "gate"        => JSON::Any.new(gate),
      "verdict"     => JSON::Any.new(verdict),
      "details"     => JSON::Any.new(details),
      "at"          => JSON::Any.new(_beh_now),
    }.to_json, actor: "evolution.proposal_gatekeeper")
    graph.add_relation(proposal_id, result.id, "gated_by", actor: "evolution.proposal_gatekeeper")
  end

  # Flip the loading mod_promotion to active on the marker event.
  #
  # Quiescent apply means this is the one and only reaction point. Matching
  # is by the marker's from_run against the promotion's recorded fork run id.
  @[Chronicle::Packs::Annotations::Behavior(name: "promotion_recorder", on: ["promote.applied"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream promotion_recorder
  def promotion_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : EvolutionSettings) : Nil
    return unless settings.enabled?
    payload = JSON.parse(event.payload)
    from_run = payload["from_run"]?.try(&.as_s?) || ""
    return if from_run.empty?

    graph.objects(type: "mod_promotion").each do |promotion|
      pdata = JSON.parse(promotion.data)
      next unless pdata["fork_run_id"]?.try(&.as_s?) == from_run && pdata["status"]?.try(&.as_s?) == "loading"

      _merge_patch(graph, promotion.id, {
        "status"                  => JSON::Any.new("active"),
        "promote_marker_event_id" => JSON::Any.new(event.id),
        "applied_counts"          => JSON::Any.new({
          "objects_created"   => JSON::Any.new((payload["objects_created"]?.try(&.as_a) || [] of JSON::Any).size),
          "objects_patched"   => JSON::Any.new((payload["objects_patched"]?.try(&.as_a) || [] of JSON::Any).size),
          "objects_removed"   => JSON::Any.new((payload["objects_removed"]?.try(&.as_a) || [] of JSON::Any).size),
          "relations_created" => JSON::Any.new((payload["relations_created"]?.try(&.as_a) || [] of JSON::Any).size),
          "relations_removed" => JSON::Any.new((payload["relations_removed"]?.try(&.as_a) || [] of JSON::Any).size),
        }),
        "at" => JSON::Any.new(_beh_now),
      }, "evolution.promotion_recorder")
      proposal_id = pdata["proposal_id"]?.try(&.as_s?)
      if proposal_id && !proposal_id.empty? && graph.get_object(proposal_id)
        _merge_patch(graph, proposal_id, {
          "status"      => JSON::Any.new("promoted"),
          "status_note" => JSON::Any.new(""),
        }, "evolution.promotion_recorder")
      end
      return
    end
  end

  # Post-adoption self-noticing (design §3 stage 6).
  #
  # Reacts to ordinary graph activity (object.created) and scans the event
  # log for behavior.failed events attributable to an adopted pack's own
  # behaviors within watch_window_events after its promote marker, raising
  # ONE reflection capability_gap per such pack.
  @[Chronicle::Packs::Annotations::Behavior(name: "watch_monitor", on: ["object.created"], creates: ["capability_gap"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream watch_monitor
  def watch_monitor(_event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : EvolutionSettings) : Nil
    return unless settings.enabled?
    window = settings.watch_window_events

    watched = {} of String => Array({String, Int32})
    promo_by_id = {} of String => {Chronicle::GraphObject, String}
    graph.objects(type: "mod_promotion").each do |promo|
      pdata = JSON.parse(promo.data)
      next unless pdata["status"]?.try(&.as_s?) == "active"
      marker_ord = _evt_ord(pdata["promote_marker_event_id"]?.try(&.as_s?))
      next if marker_ord.nil?
      promo_by_id[promo.id] = {promo, pdata["pack_name"]?.try(&.as_s?) || ""}
      behaviors = if meta = pdata["metadata"]?.try(&.as_h)
                    meta["behaviors"]?.try(&.as_a) || [] of JSON::Any
                  else
                    [] of JSON::Any
                  end
      behaviors.each do |bname|
        name = bname.as_s
        if !name.empty?
          watched[name] = (watched[name]? || [] of {String, Int32}) << {promo.id, marker_ord}
        end
      end
    end
    return if watched.empty?

    already = Set(String).new
    graph.objects(type: "capability_gap").each do |gap_obj|
      gdata = JSON.parse(gap_obj.data)
      if gdata["kind"]?.try(&.as_s?) == "reflection" && gdata["status"]?.try(&.as_s?) == "open"
        if meta = gdata["metadata"]?.try(&.as_h)
          if pid = meta["promotion_id"]?.try(&.as_s?)
            already << pid
          end
        end
      end
    end
    pending = promo_by_id.keys.reject { |pid| already.includes?(pid) }
    return if pending.empty?

    min_marker = watched.values.flat_map { |lst| lst.map(&.[1]) }.min?
    return if min_marker.nil?

    counts = {} of String => Int32
    graph.events.sort_by(&.sequence).reverse_each do |log_event|
      f_ord = _evt_ord(log_event.id)
      if !f_ord.nil? && f_ord <= min_marker
        break
      end
      next if log_event.type != "behavior.failed" || f_ord.nil?
      bname = JSON.parse(log_event.payload)["behavior"]?.try(&.as_s?) || ""
      if lst = watched[bname]?
        lst.each do |pid, marker_ord|
          if pending.includes?(pid) && marker_ord < f_ord && f_ord <= marker_ord + window
            counts[pid] = (counts[pid]? || 0) + 1
          end
        end
      end
    end

    counts.each do |pid, count|
      _promo, pack_name = promo_by_id[pid]
      graph.add_object("capability_gap", {
        "kind"            => JSON::Any.new("reflection"),
        "description"     => JSON::Any.new("adopted pack #{pack_name.inspect} produced #{count} behavior failure(s) within the post-adoption watch window"),
        "evidence_refs"   => JSON::Any.new([] of JSON::Any),
        "injection_flags" => JSON::Any.new([] of JSON::Any),
        "status"          => JSON::Any.new("open"),
        "metadata"        => JSON::Any.new({
          "promotion_id"   => JSON::Any.new(pid),
          "pack_name"      => JSON::Any.new(pack_name),
          "watch_failures" => JSON::Any.new(count),
          "source"         => JSON::Any.new("watch_monitor"),
        }),
      }.to_json, actor: "evolution.watch_monitor")
    end
  end
end

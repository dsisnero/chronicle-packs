require "json"
require "html"
require "toml"
require "similar"

module Chronicle::Packs::Evolution
  # The adoption decision surface (design §3 stage 4).
  #
  # "The owner approved it" has to mean "the owner read it", so this module
  # turns one mod_proposal into a single reviewable page: who authored it,
  # which gap it claims to fix, the FULL source diff (small by gate 7, so
  # actually readable), the declared surface, every gate verdict, the trial
  # summary, the promote diff counts, the fork run id, and any injection
  # flags, loudly.
  #
  # Everything comes from graph state alone: `build_review` is a pure read
  # over the objects the pipeline already wrote, and `render_review_html` is
  # a deterministic renderer over that model. No candidate code is imported,
  # executed, or even written to disk here; agent-authored text is escaped
  # everywhere it appears. The unified diff rides the `similar` shard
  # (dsisnero/similar.cr) configured to match Python difflib's `lineterm=""`
  # line output (context radius 3, no newline hints).
  #
  # Ported from upstream packs/evolution/review.py (revision
  # 6639a5385518ad49f74813373c85cf96eff9adc0).
  module Review
    # Statuses where an approve/deny decision is still meaningful.
    DECIDABLE = Set{"drafted", "gated", "trialed", "pending_approval"}

    # ---------------------------------------------------------- the model

    def self._gap_view(graph : Chronicle::GraphProjection, gap_id : String) : Hash(String, JSON::Any)?
      return nil if gap_id.empty?
      gap = graph.get_object(gap_id)
      return nil if gap.nil? || gap.type != "capability_gap"
      data = JSON.parse(gap.data).as_h
      {
        "id"              => JSON::Any.new(gap.id),
        "kind"            => data["kind"]? || JSON::Any.new(""),
        "description"     => data["description"]? || JSON::Any.new(""),
        "status"          => data["status"]? || JSON::Any.new(""),
        "evidence_refs"   => data["evidence_refs"]? || JSON::Any.new([] of JSON::Any),
        "injection_flags" => data["injection_flags"]? || JSON::Any.new([] of JSON::Any),
      }
    end

    # The diff baseline: the artifacts behind the newest non-disabled
    # promotion of the same pack name (what is running today). A first
    # adoption has no baseline; the whole source renders as added.
    def self._baseline_files(graph : Chronicle::GraphProjection, pack_name : String, proposal_id : String) : {Hash(String, String), String}
      promotions = graph.objects(type: "mod_promotion").select do |promotion|
        data = JSON.parse(promotion.data)
        data["pack_name"]?.try(&.as_s?) == pack_name &&
          (data["status"]?.try(&.as_s?) == "active" || data["status"]?.try(&.as_s?) == "loading") &&
          data["proposal_id"]?.try(&.as_s?) != proposal_id
      end
      if promotions.empty?
        return Tuple.new({} of String => String, "new pack (no adopted version to diff against)")
      end
      current = promotions[-1]
      base_proposal = graph.get_object(JSON.parse(current.data)["proposal_id"]?.try(&.as_s?) || "")
      if base_proposal.nil?
        return Tuple.new({} of String => String, "new pack (baseline proposal missing)")
      end
      begin
        files = Materialize.proposal_files(graph, base_proposal)
      rescue PackError
        return Tuple.new({} of String => String, "new pack (baseline artifacts missing)")
      end
      label = "adopted version (promotion #{current.id}, bundle #{JSON.parse(current.data)["bundle_hash"]?.try(&.as_s?) || ""})"
      label = label[0, 20 + 19] # keep "adopted version (promotion X, bundle sha256:abc…)" shape
      {files, label}
    end

    # Per-file unified diffs, every path from either side, sorted. Lines are
    # produced by the `similar` shard configured to match Python difflib
    # with `lineterm=""` (context radius 3, no trailing newlines on lines).
    def self._unified_diff(baseline : Hash(String, String), files : Hash(String, String)) : Array(Hash(String, JSON::Any))
      out = [] of Hash(String, JSON::Any)
      (baseline.keys.to_set | files.keys.to_set).to_a.sort.each do |path|
        old = baseline[path]? || ""
        new = files[path]? || ""
        lines = if old == new
                  [] of String
                else
                  diff = Similar::TextDiffConfig.new.diff_slices(old.lines, new.lines)
                  text = diff.unified_diff.context_radius(3).header("adopted/#{path}", "proposed/#{path}").to_s
                  text.lines
                end
        status = old == new ? "unchanged" : (old.empty? ? "added" : (new.empty? ? "removed" : "modified"))
        out << {
          "path"       => JSON::Any.new(path),
          "status"     => JSON::Any.new(status),
          "lines"      => JSON::Any.new(lines.map { |line| JSON::Any.new(line) }),
          "size_bytes" => JSON::Any.new(new.bytesize),
        }
      end
      out
    end

    # Parse the proposal's manifest.toml text (never trusted, only
    # displayed; the gates verified it against the source already).
    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _manifest_view
    def self._manifest_view(files : Hash(String, String)) : Hash(String, JSON::Any)
      text = files["manifest.toml"]? || ""
      root = begin
        TOML.parse(text)
      rescue ex
        return {"error" => JSON::Any.new("manifest.toml does not parse: #{ex.message}")}
      end
      pack = root["pack"]?.try(&.as_h) || {} of String => TOML::Any
      surface = root["surface"]?.try(&.as_h) || {} of String => TOML::Any
      provenance = pack["provenance"]?.try(&.as_h) || {} of String => TOML::Any
      caps = (surface["capabilities"]?.try(&.as_a) || [] of TOML::Any).map do |cap|
        ch = cap.as_h
        {"key"        => JSON::Any.new("#{ch["provider"]?.try(&.as_s?) || "?"}.#{ch["capability"]?.try(&.as_s?) || "?"}"),
         "risk_class" => JSON::Any.new(ch["risk_class"]?.try(&.as_s?) || "?")}
      end

      {
        "name"           => JSON::Any.new(pack["name"]?.try(&.as_s?) || ""),
        "version"        => JSON::Any.new(pack["version"]?.try(&.as_s?) || ""),
        "description"    => JSON::Any.new(pack["description"]?.try(&.as_s?) || ""),
        "authored_by"    => JSON::Any.new(provenance["authored_by"]?.try(&.as_s?) || ""),
        "behaviors"      => JSON::Any.new((surface["behaviors"]?.try(&.as_a) || [] of TOML::Any).map { |behavior| JSON::Any.new(behavior.as_s) }),
        "tools"          => JSON::Any.new((surface["tools"]?.try(&.as_a) || [] of TOML::Any).map { |tool| JSON::Any.new(tool.as_s) }),
        "object_types"   => JSON::Any.new((surface["object_types"]?.try(&.as_a) || [] of TOML::Any).map { |obj_type| JSON::Any.new(obj_type.as_s) }),
        "relation_types" => JSON::Any.new((surface["relation_types"]?.try(&.as_a) || [] of TOML::Any).map { |rel| JSON::Any.new(rel.as_s) }),
        "capabilities"   => JSON::Any.new(caps.map { |cap| JSON::Any.new(cap) }),
        "consumes"       => JSON::Any.new((surface["consumes"]?.try(&.as_a) || [] of TOML::Any).map { |consume| JSON::Any.new(consume.as_s) }),
      }
    end

    # The drafting record (llm-author-design §4): what the author READ.
    def self._drafting_view(graph : Chronicle::GraphProjection, record_id : String) : Hash(String, JSON::Any)?
      return nil if record_id.empty?
      record = graph.get_object(record_id)
      if record.nil? || record.type != "drafting_context"
        return {"id" => JSON::Any.new(record_id), "missing" => JSON::Any.new(true)}
      end
      data = JSON.parse(record.data).as_h
      {
        "id"                => JSON::Any.new(record.id),
        "missing"           => JSON::Any.new(false),
        "model"             => data["model"]? || JSON::Any.new(""),
        "charter_hash"      => data["charter_hash"]? || JSON::Any.new(""),
        "gap_id"            => data["gap_id"]? || JSON::Any.new(""),
        "structured_fields" => data["structured_fields"]? || JSON::Any.new([] of JSON::Any),
        "surface_sources"   => data["surface_sources"]? || JSON::Any.new([] of JSON::Any),
        "owner_input_ids"   => data["owner_input_ids"]? || JSON::Any.new([] of JSON::Any),
        "injection_flags"   => data["injection_flags"]? || JSON::Any.new([] of JSON::Any),
        "at"                => data["at"]? || JSON::Any.new(""),
      }
    end

    def self._pending_call(graph : Chronicle::GraphProjection, proposal_id : String) : Hash(String, JSON::Any)?
      graph.objects(type: "capability_call").each do |call|
        data = JSON.parse(call.data).as_h
        input = data["input_data"]?.try(&.as_h) || {} of String => JSON::Any
        if data["provider_name"]?.try(&.as_s?) == "evolution" &&
           data["capability_name"]?.try(&.as_s?) == "adopt_proposal" &&
           input["proposal_id"]?.try(&.as_s?) == proposal_id &&
           data["status"]?.try(&.as_s?) == "policy_checking"
          return {
            "call_id"     => JSON::Any.new(call.id),
            "proposed_by" => data["proposed_by"]? || JSON::Any.new(""),
            "proposed_at" => data["proposed_at"]? || JSON::Any.new(""),
            "risk_class"  => data["risk_class"]? || JSON::Any.new(""),
          }
        end
      end
      nil
    end

    # Assemble the full review model for one proposal, from graph state.
    #
    # Raises KeyError when the proposal does not exist; everything else
    # degrades to explicit placeholders (a review page must render even
    # for a half-broken proposal).
    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream build_review
    def self.build_review(graph : Chronicle::GraphProjection, proposal_id : String) : Hash(String, JSON::Any)
      proposal = graph.get_object(proposal_id)
      if proposal.nil? || proposal.type != "mod_proposal"
        raise KeyError.new("no mod_proposal #{proposal_id.inspect}")
      end
      data = JSON.parse(proposal.data).as_h

      files_error = ""
      files = begin
        Materialize.proposal_files(graph, proposal)
      rescue ex : PackError
        files_error = ex.message || "missing source artifacts"
        {} of String => String
      end

      gap = _gap_view(graph, data["gap_id"]?.try(&.as_s?) || "")
      baseline, baseline_label = _baseline_files(graph, data["pack_name"]?.try(&.as_s?) || "", proposal_id)

      gates = graph.objects(type: "gate_result").select { |gate_item| JSON.parse(gate_item.data)["proposal_id"]?.try(&.as_s?) == proposal_id }.map do |gate_obj|
        gd = JSON.parse(gate_obj.data).as_h
        {"gate" => gd["gate"]? || JSON::Any.new(""), "verdict" => gd["verdict"]? || JSON::Any.new(""),
         "details" => gd["details"]? || JSON::Any.new(""), "at" => gd["at"]? || JSON::Any.new("")}
      end

      trials = graph.objects(type: "mod_trial").select { |trial_item| JSON.parse(trial_item.data)["proposal_id"]?.try(&.as_s?) == proposal_id }.map do |trial_obj|
        td = JSON.parse(trial_obj.data).as_h
        {"id" => JSON::Any.new(trial_obj.id), "fork_run_id" => td["fork_run_id"]? || JSON::Any.new(""),
         "forked_at_event" => td["forked_at_event"]? || JSON::Any.new(""),
         "verdict" => td["verdict"]? || JSON::Any.new(""),
         "eval_summary" => td["eval_summary"]? || JSON::Any.new({} of String => JSON::Any),
         "diff_summary" => td["diff_summary"]? || JSON::Any.new({} of String => JSON::Any),
         "failures" => td["failures"]? || JSON::Any.new([] of JSON::Any),
         "at" => td["at"]? || JSON::Any.new("")}
      end

      promotions = graph.objects(type: "mod_promotion").select { |promo_item| JSON.parse(promo_item.data)["proposal_id"]?.try(&.as_s?) == proposal_id }.map do |promo_obj|
        pd = JSON.parse(promo_obj.data).as_h
        {"id" => JSON::Any.new(promo_obj.id), "status" => pd["status"]? || JSON::Any.new(""),
         "fork_run_id" => pd["fork_run_id"]? || JSON::Any.new(""),
         "bundle_hash" => pd["bundle_hash"]? || JSON::Any.new(""), "at" => pd["at"]? || JSON::Any.new("")}
      end

      drafting = _drafting_view(graph, data["drafting_context_id"]?.try(&.as_s?) || "")

      flags = Set(String).new
      (data["injection_flags"]?.try(&.as_a) || [] of JSON::Any).each { |flag| flags << flag.as_s }
      gap.try(&.["injection_flags"].as_a).try(&.each { |flag| flags << flag.as_s })
      drafting.try(&.["injection_flags"].as_a).try(&.each { |flag| flags << flag.as_s })

      auto_retries = 0
      if meta = data["metadata"]?.try(&.as_h)
        auto_retries = meta["auto_retries"]?.try(&.as_i?) || 0
      end

      {
        "proposal" => JSON::Any.new({
          "id"           => JSON::Any.new(proposal.id),
          "pack_name"    => data["pack_name"]? || JSON::Any.new(""),
          "pack_version" => data["pack_version"]? || JSON::Any.new(""),
          "status"       => data["status"]? || JSON::Any.new(""),
          "status_note"  => data["status_note"]? || JSON::Any.new(""),
          "authored_by"  => data["authored_by"]? || JSON::Any.new(""),
          "rationale"    => data["rationale"]? || JSON::Any.new(""),
          "bundle_hash"  => data["bundle_hash"]? || JSON::Any.new(""),
          "auto_retries" => JSON::Any.new(auto_retries),
        }),
        "gap"             => gap.nil? ? JSON::Any.new(nil) : JSON::Any.new(gap),
        "drafting"        => drafting.nil? ? JSON::Any.new(nil) : JSON::Any.new(drafting),
        "files_error"     => JSON::Any.new(files_error),
        "baseline_label"  => JSON::Any.new(baseline_label),
        "diff"            => JSON::Any.new(_unified_diff(baseline, files).map { |entry| JSON::Any.new(entry) }),
        "manifest"        => JSON::Any.new(_manifest_view(files)),
        "gates"           => JSON::Any.new(gates.map { |gate| JSON::Any.new(gate) }),
        "trial"           => trials.empty? ? JSON::Any.new(nil) : JSON::Any.new(trials[-1]),
        "trial_count"     => JSON::Any.new(trials.size),
        "promotions"      => JSON::Any.new(promotions.map { |promo| JSON::Any.new(promo) }),
        "injection_flags" => JSON::Any.new(flags.to_a.sort.map { |flag| JSON::Any.new(flag) }),
        "pending_call"    => (_call = _pending_call(graph, proposal_id)).nil? ? JSON::Any.new(nil) : JSON::Any.new(_call),
        "decidable"       => JSON::Any.new(DECIDABLE.includes?(data["status"]?.try(&.as_s?) || "")),
      }
    end

    # ---------------------------------------------------------- the page

    CSS = <<-CSS
    body { font-family: -apple-system, 'Segoe UI', sans-serif; margin: 0;
           background: #f5f5f4; color: #1c1917; }
    main { max-width: 960px; margin: 0 auto; padding: 24px 16px 64px; }
    h1 { font-size: 22px; } h2 { font-size: 16px; margin-top: 32px;
         border-bottom: 1px solid #d6d3d1; padding-bottom: 6px; }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { text-align: left; padding: 5px 10px; border-bottom: 1px solid #e7e5e4;
             vertical-align: top; }
    code, pre { font-family: ui-monospace, 'SF Mono', Menlo, monospace;
                font-size: 12px; }
    pre { background: #fff; border: 1px solid #d6d3d1; border-radius: 6px;
          padding: 10px; overflow-x: auto; line-height: 1.45; }
    .banner { border-radius: 8px; padding: 12px 16px; margin: 12px 0;
              font-weight: 600; }
    .banner.agent { background: #fef3c7; border: 2px solid #d97706; color: #92400e; }
    .banner.human { background: #ecfdf5; border: 2px solid #059669; color: #065f46; }
    .banner.taint { background: #fee2e2; border: 2px solid #dc2626; color: #991b1b; }
    .banner.clean { background: #f0fdf4; border: 1px solid #86efac; color: #166534;
                    font-weight: 400; }
    .verdict-pass { color: #059669; font-weight: 600; }
    .verdict-fail { color: #dc2626; font-weight: 600; }
    .verdict-suspended { color: #d97706; font-weight: 600; }
    .diff-add { color: #059669; display: block; background: #f0fdf4; }
    .diff-del { color: #dc2626; display: block; background: #fef2f2; }
    .diff-hunk { color: #7c3aed; display: block; }
    .muted { color: #78716c; font-size: 12px; }
    .decision { background: #fff; border: 2px solid #1c1917; border-radius: 8px;
                padding: 16px; margin-top: 24px; }
    .decision button { font-size: 14px; padding: 8px 22px; border-radius: 6px;
                       border: 1px solid #1c1917; cursor: pointer; margin-right: 8px; }
    .decision .approve { background: #059669; color: #fff; border-color: #047857; }
    .decision .deny { background: #fff; color: #991b1b; border-color: #991b1b; }
    CSS

    DECISION_JS = <<-JS
    async function decide(decision) {
      const call_id = document.getElementById('call-id').value;
      const approver = document.getElementById('approver-ref').value;
      const token = document.getElementById('approval-token').value;
      const body = {call_id: call_id, decision: decision, approver_ref: approver};
      if (decision === 'deny')
        body.reason = document.getElementById('decision-note').value;
      else
        body.note = document.getElementById('decision-note').value;
      const headers = {'Content-Type': 'application/json'};
      if (token) headers['Authorization'] = 'Bearer ' + token;
      const res = await fetch('/approvals', {method: 'POST',
        headers: headers,
        body: JSON.stringify(body)});
      const out = await res.json();
      document.getElementById('decision-result').textContent =
        JSON.stringify(out, null, 2);
      if (out.ok) setTimeout(() => location.reload(), 800);
    }
    JS

    def self._esc(value : JSON::Any?) : String
      HTML.escape(value.try(&.as_s?) || (value.nil? ? "" : value.raw.to_s))
    end

    def self._esc(value : String) : String
      HTML.escape(value)
    end

    def self._esc_s(value : String) : String
      HTML.escape(value)
    end

    def self._kv_rows(pairs : Array({String, String})) : String
      pairs.map { |key, value| "<tr><th>#{_esc_s(key)}</th><td>#{_esc_s(value)}</td></tr>" }.join
    end

    def self._diff_html(diff : Array(Hash(String, JSON::Any))) : String
      parts = [] of String
      diff.each do |entry|
        path = entry["path"].as_s
        status = entry["status"].as_s
        size = entry["size_bytes"].as_i
        lines = entry["lines"].as_a.map(&.as_s)
        parts << "<h3><code>#{_esc_s(path)}</code> <span class='muted'>(#{_esc_s(status)}, #{size} bytes)</span></h3>"
        if lines.empty?
          parts << "<p class='muted'>unchanged</p>"
          next
        end
        rendered = [] of String
        lines.each do |line|
          esc = _esc_s(line)
          if line.starts_with?("+") && !line.starts_with?("+++")
            rendered << "<span class='diff-add'>#{esc}</span>"
          elsif line.starts_with?("-") && !line.starts_with?("---")
            rendered << "<span class='diff-del'>#{esc}</span>"
          elsif line.starts_with?("@@")
            rendered << "<span class='diff-hunk'>#{esc}</span>"
          else
            rendered << "<span>#{esc}</span>"
          end
        end
        parts << "<pre>" + rendered.join("\n") + "</pre>"
      end
      parts.join
    end

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream render_review_html
    def self.render_review_html(review : Hash(String, JSON::Any)) : String
      p = review["proposal"].as_h
      parts = [] of String
      parts << "<main><h1>Adoption review: <code>#{_esc(p["pack_name"])}</code> v#{_esc(p["pack_version"])}</h1>"

      author = p["authored_by"]?.try(&.as_s?) || "unknown"
      author_class = author.in?({"human", "owner"}) ? "human" : "agent"
      parts << "<div class='banner #{author_class}'>AUTHORED BY: #{_esc_s(author.upcase)}"
      parts << "" if author_class == "human"
      if author_class == "human"
        parts[-1] = "<div class='banner #{author_class}'>AUTHORED BY: #{_esc_s(author.upcase)}</div>"
      else
        parts[-1] = "<div class='banner #{author_class}'>AUTHORED BY: #{_esc_s(author.upcase)} &mdash; this code was written by the assistant. Read the diff before approving.</div>"
      end

      flags = review["injection_flags"].as_a.map(&.as_s)
      if !flags.empty?
        parts << "<div class='banner taint'>INJECTION FLAGS ON THIS LINEAGE: " + flags.map { |flag| _esc_s(flag) }.join(", ") + "</div>"
      else
        parts << "<div class='banner clean'>No injection flags on this proposal or its gap lineage.</div>"
      end

      parts << "<h2>Proposal</h2><table>"
      status_note = p["status_note"]?.try(&.as_s?) || ""
      status = (p["status"]?.try(&.as_s?) || "") + (status_note.empty? ? "" : " (#{status_note})")
      parts << _kv_rows([
        {"proposal id", p["id"].as_s},
        {"status", status},
        {"rationale", (p["rationale"]?.try(&.as_s?) || "").empty? ? "(none given)" : p["rationale"].as_s},
        {"bundle hash (the approval pin)", p["bundle_hash"]?.try(&.as_s?) || ""},
        {"automatic conflict retries so far", (p["auto_retries"]?.try(&.as_i?) || 0).to_s},
      ])
      parts << "</table>"

      drafting = review["drafting"]?
      parts << "<h2>What the author read (drafting record)</h2>"
      if drafting.nil? || drafting.raw.nil?
        parts << "<p class='muted'>No drafting record: a pre-record scripted or owner submission. An LLM-authored proposal MUST carry one.</p>"
      elsif drafting.as_h["missing"]?.try(&.raw) == true
        parts << "<p class='verdict-fail'>Drafting record #{_esc(drafting.as_h["id"])} is referenced but absent from the graph. Do not approve a draft whose context cannot be inspected.</p>"
      else
        d = drafting.as_h
        d_flags = (d["injection_flags"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
        parts << "<table>" + _kv_rows([
          {"record id", d["id"].as_s},
          {"author", d["model"]?.try(&.as_s?) || ""},
          {"charter hash (the author's pinned instructions)", (d["charter_hash"]?.try(&.as_s?) || "").empty? ? "(missing)" : d["charter_hash"].as_s},
          {"structured gap fields admitted (section b)", _join_or_none(d["structured_fields"]?)},
          {"surface sources admitted (section c)", _join_or_none(d["surface_sources"]?)},
          {"owner inputs admitted (section d)", _join_or_none(d["owner_input_ids"]?)},
          {"taint union over admitted objects", d_flags.empty? ? "none" : d_flags.join(", ")},
          {"at", d["at"]?.try(&.as_s?) || ""},
        ]) + "</table>"
        parts << "<p class='muted'>Memory, profile, and tool text are excluded from the author frame by origin (llm-author-design §3); this record lists everything that crossed.</p>"
      end

      gap = review["gap"]?
      parts << "<h2>Gap this claims to fix</h2>"
      if !gap.nil? && !gap.raw.nil?
        g = gap.as_h
        parts << "<table>" + _kv_rows([
          {"gap id", g["id"].as_s}, {"kind", g["kind"]?.try(&.as_s?) || ""},
          {"description", g["description"]?.try(&.as_s?) || ""},
          {"gap injection flags", _join_or_none(g["injection_flags"]?)},
          {"evidence refs", _join_or_none(g["evidence_refs"]?)},
        ]) + "</table>"
      else
        parts << "<p class='muted'>No linked capability_gap (direct submission).</p>"
      end

      m = review["manifest"].as_h
      parts << "<h2>Declared surface (from manifest.toml)</h2>"
      if m["error"]?
        parts << "<p class='verdict-fail'>#{_esc(m["error"])}</p>"
      else
        caps = (m["capabilities"]?.try(&.as_a) || [] of JSON::Any).map { |cap| "#{cap.as_h["key"].as_s} (#{cap.as_h["risk_class"].as_s})" }.join(", ")
        caps = "none" if caps.empty?
        parts << "<table>" + _kv_rows([
          {"manifest authored_by", (m["authored_by"]?.try(&.as_s?) || "").empty? ? "(missing)" : m["authored_by"].as_s},
          {"behaviors", _join_or_none(m["behaviors"]?)},
          {"tools", _join_or_none(m["tools"]?)},
          {"object types", _join_or_none(m["object_types"]?)},
          {"relation types", _join_or_none(m["relation_types"]?)},
          {"capabilities it registers", caps},
          {"consumes (outbound reach)", _join_or_none(m["consumes"]?)},
        ]) + "</table>"
      end

      parts << "<h2>Gate verdicts</h2>"
      gates = review["gates"].as_a
      if !gates.empty?
        rows = gates.map do |gate|
          gh = gate.as_h
          "<tr><td><code>#{_esc(gh["gate"])}</code></td><td class='verdict-#{_esc(gh["verdict"])}'>#{_esc(gh["verdict"])}</td><td>#{_esc(gh["details"])}</td><td class='muted'>#{_esc(gh["at"])}</td></tr>"
        end.join
        parts << "<table><tr><th>gate</th><th>verdict</th><th>details</th><th>at</th></tr>" + rows + "</table>"
      else
        parts << "<p class='verdict-fail'>No gate results recorded. Do not approve an ungated proposal.</p>"
      end

      trial = review["trial"]?
      parts << "<h2>Fork trial</h2>"
      if !trial.nil? && !trial.raw.nil?
        t = trial.as_h
        eval_rows = (t["eval_summary"]?.try(&.as_h) || {} of String => JSON::Any).to_a.sort_by(&.[0]).map { |key, value| {key, value.as_s} }
        diff_rows = (t["diff_summary"]?.try(&.as_h) || {} of String => JSON::Any).to_a.sort_by(&.[0]).map { |key, value| {key, value.as_s} }
        failures = (t["failures"]?.try(&.as_a) || [] of JSON::Any).map(&.as_h)
        kv_pairs = [] of {String, String}
        kv_pairs << {"verdict", t["verdict"]?.try(&.as_s?) || ""}
        kv_pairs << {"fork run id", t["fork_run_id"]?.try(&.as_s?) || ""}
        kv_pairs << {"forked at event", t["forked_at_event"]?.try(&.as_s?) || ""}
        kv_pairs << {"trials run", review["trial_count"].as_i.to_s}
        kv_pairs << {"at", t["at"]?.try(&.as_s?) || ""}
        kv_pairs.concat(eval_rows)
        kv_pairs.concat(diff_rows.map { |key, value| {"promote delta: #{key}", value} })
        parts << "<table>" + _kv_rows(kv_pairs) + "</table>"
        if !failures.empty?
          failure_bodies = failures.map do |failure|
            failure.to_a.map { |key, value| "#{key}: #{value.as_s}" }.join("\n")
          end
          parts << "<h3 class='verdict-fail'>Trial failures</h3><pre>#{_esc_s(failure_bodies.join("\n\n"))}</pre>"
        else
          parts << "<p class='verdict-pass'>Zero candidate failures in the trial.</p>"
        end
      else
        parts << "<p class='verdict-fail'>No trial recorded. Do not approve an untrialed proposal.</p>"
      end

      promotions = review["promotions"].as_a
      if !promotions.empty?
        parts << "<h2>Prior promotion records for this proposal</h2><table><tr><th>id</th><th>status</th><th>fork run</th><th>at</th></tr>"
        parts << promotions.map do |promo|
          ph = promo.as_h
          "<tr><td>#{_esc(ph["id"])}</td><td>#{_esc(ph["status"])}</td><td>#{_esc(ph["fork_run_id"])}</td><td>#{_esc(ph["at"])}</td></tr>"
        end.join + "</table>"
      end

      parts << "<h2>Full source diff</h2><p class='muted'>Baseline: #{_esc_s(review["baseline_label"].as_s)}</p>"
      files_error = review["files_error"]?.try(&.as_s?) || ""
      unless files_error.empty?
        parts << "<p class='verdict-fail'>#{_esc_s(files_error)}</p>"
      end
      parts << _diff_html(review["diff"].as_a.map(&.as_h))

      pending = review["pending_call"]?
      if !pending.nil? && !pending.raw.nil?
        pc = pending.as_h
        parts << "<div class='decision'><h2 style='margin-top:0;border:0'>Decision</h2>"
        parts << "<p>Held call <code>#{_esc(pc["call_id"])}</code> (risk <b>#{_esc(pc["risk_class"])}</b>), proposed by <code>#{_esc(pc["proposed_by"])}</code> at #{_esc(pc["proposed_at"])}.</p>"
        parts << "<input type='hidden' id='call-id' value='#{_esc(pc["call_id"])}'>"
        parts << "<p><label>Approver ref: <input id='approver-ref' size='28' placeholder='owner@example.com'></label></p>"
        parts << "<p><label>Approval token: <input id='approval-token' type='password' size='28' autocomplete='off'></label> <span class='muted'>authenticates the channel; the approver ref is still verified against principals</span></p>"
        parts << "<p><label>Note / denial reason: <input id='decision-note' size='48'></label></p>"
        parts << "<button class='approve' onclick=\"decide('approve')\">Approve adoption</button>"
        parts << "<button class='deny' onclick=\"decide('deny')\">Deny</button>"
        parts << "<pre id='decision-result' class='muted'></pre></div>"
      elsif review["decidable"].as_bool
        parts << "<div class='decision'><p>No held approval call yet: adoption has not been requested for this proposal (<code>request_adoption_fn</code> creates the held call).</p></div>"
      else
        parts << "<div class='decision'><p>Status is <b>#{_esc(p["status"])}</b>; there is nothing to decide here.</p></div>"
      end

      parts << "</main>"
      "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Adoption review: #{_esc_s(p["pack_name"].as_s)}</title><style>#{CSS}</style><script>#{DECISION_JS}</script></head><body>" + parts.join + "</body></html>"
    end

    def self._join_or_none(value : JSON::Any?) : String
      if value.nil?
        "none"
      else
        arr = value.as_a.map(&.as_s)
        arr.empty? ? "none" : arr.join(", ")
      end
    end

    # The /approvals landing page: every held call, with evolution
    # adoptions linking to their full review page instead of raw JSON.
    def self.render_approvals_index_html(graph : Chronicle::GraphProjection) : String
      rows = [] of String
      ToolGateway.pending_approvals_fn(graph).each do |call|
        key = "#{call["provider_name"].as_s}.#{call["capability_name"].as_s}"
        proposal_id = ""
        if key == "evolution.adopt_proposal"
          input = call["input_data"]?.try(&.as_h) || {} of String => JSON::Any
          proposal_id = input["proposal_id"]?.try(&.as_s?) || ""
        end
        action = if proposal_id.empty?
                   "<span class='muted'>JSON only</span>"
                 else
                   "<a href='/approvals/review?proposal_id=#{_esc_s(proposal_id)}'>full review</a>"
                 end
        rows << "<tr><td><code>#{_esc(call["call_id"])}</code></td><td><code>#{_esc_s(key)}</code></td><td>#{_esc(call["risk_class"])}</td><td>#{_esc_s(call["proposed_by"]?.try(&.as_s?) || "")}</td><td>#{_esc_s(call["proposed_at"]?.try(&.as_s?) || "")}</td><td>#{action}</td></tr>"
      end
      table = if rows.empty?
                "<p class='muted'>Nothing is waiting for approval.</p>"
              else
                "<table><tr><th>call</th><th>capability</th><th>risk</th><th>proposed by</th><th>at</th><th></th></tr>" + rows.join + "</table>"
              end

      needs_owner = begin
        graph.objects(type: "mod_proposal").select { |mod_prop| JSON.parse(mod_prop.data)["status"]?.try(&.as_s?) == "needs_owner" }
      rescue ex
        [] of Chronicle::GraphObject
      end
      stuck = ""
      if !needs_owner.empty?
        stuck = "<h2>Proposals needing owner action</h2><table><tr><th>proposal</th><th>pack</th><th>note</th><th></th></tr>" + needs_owner.map do |owner_obj|
          od = JSON.parse(owner_obj.data).as_h
          "<tr><td><code>#{_esc_s(owner_obj.id)}</code></td><td>#{_esc_s(od["pack_name"]?.try(&.as_s?) || "")}</td><td>#{_esc_s(od["status_note"]?.try(&.as_s?) || "")}</td><td><a href='/approvals/review?proposal_id=#{_esc_s(owner_obj.id)}'>review</a></td></tr>"
        end.join + "</table>"
      end

      "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Approvals</title><style>#{CSS}</style></head><body><main><h1>Held approvals</h1><p class='muted'>The graph is the source of truth: a pending approval IS a capability_call at status policy_checking. Evolution adoptions get a full review page; approve nothing you have not read.</p>" + table + stuck + "</main></body></html>"
    end
  end
end

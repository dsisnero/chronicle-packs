require "json"

module Chronicle::Packs::Bridges
  # Diligence-Core Bridge behaviors. Ported from upstream
  # packs/bridges/diligence_core.py.
  #
  # Subscribes to Diligence pack object.created events and creates parallel
  # Core primitive objects so Diligence outputs appear alongside outputs from
  # all other packs in the shared graph:
  #
  #   diligence.document  → core.source       (kind=document, content=summary, url=url)
  #   diligence.claim     → core.observation  (text=text, confidence=confidence)
  #   diligence.memo      → core.artifact     (kind=memo, content=markdown, status=draft)
  #   diligence.risk      → core.evaluation   (judgment=severity, rationale=description)
  #
  # All Core objects carry a `derived_from` relation back to their Diligence
  # origin; bridged observations also wire `grounds` to any bridged source
  # document. The bridge is non-destructive: it never modifies Diligence
  # objects.
  #
  # Registries (class-level, cleared between fixtures via
  # DiligenceCore.clear_bridge_registry):
  #   bridge_seen: diligence_object_id → core_object_id

  # The upstream `_BRIDGE_SEEN` registry + payload reader live in their own
  # nested module (the DSL pack macro assumes direct module constants are
  # types, so the registry must stay out of the `Bridges` module constant
  # space).
  module DiligenceCore
    # diligence_object_id → core_object_id.
    class_property bridge_seen = {} of String => String

    # Reset the bridge registry — call between test fixtures.
    def self.clear_bridge_registry : Nil
      self.bridge_seen = {} of String => String
    end

    # Read the flat chronicle object.created payload (id + data), mirroring
    # upstream's `event.payload.get("object", {})` read of the nested shape.
    def self._payload(event : Chronicle::Event) : {String?, Hash(String, JSON::Any)}
      raw = JSON.parse(event.payload)
      id = raw["id"]?.try(&.as_s?)
      data = raw["data"]?.try(&.as_h) || {} of String => JSON::Any
      {id, data}
    end

    # Upstream uses Python `or`, which is falsy on empty string — fall back
    # to the default (Crystal's `||` only treats nil as falsy).
    def self._or(value : String?, default : String) : String
      value.nil? || value.empty? ? default : value
    end

    # Assemble the memo artifact's markdown body (upstream memo_to_artifact).
    def self._memo_content(company_id : String, summary : String, key_claims : Array(JSON::Any), thesis_qs : Array(JSON::Any), open_contras : Array(JSON::Any), risks : Array(JSON::Any)) : String
      content_parts = [] of String
      content_parts << "# Diligence Memo: #{company_id}\n"
      unless summary.empty?
        content_parts << "## Summary\n#{summary}\n"
      end
      unless key_claims.empty?
        content_parts << "## Key Claims\n" + key_claims.map { |claim| "- #{claim.as_s}" }.join("\n")
      end
      unless thesis_qs.empty?
        content_parts << "\n## Thesis Questions Addressed\n" + thesis_qs.map { |question| "- #{question.as_s}" }.join("\n")
      end
      unless open_contras.empty?
        content_parts << "\n## Open Contradictions\n" + open_contras.map { |contradiction| "- #{contradiction.as_s}" }.join("\n")
      end
      unless risks.empty?
        content_parts << "\n## Risks\n" + risks.map { |risk| "- #{risk.as_s}" }.join("\n")
      end
      content_parts.join("\n")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # document  →  source
  # ──────────────────────────────────────────────────────────────────────────

  # Map a Diligence document to a Core source.
  #
  # Diligence document fields: title, url, company_id, summary, published_at
  # Core source fields: kind, content, url, metadata
  @[Chronicle::Packs::Annotations::Behavior(name: "document_to_source", on: ["object.created"], where: {"type" => "document"}, creates: ["source"])]
  def document_to_source(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    doc_id, data = DiligenceCore._payload(event)
    return if doc_id.nil? || DiligenceCore.bridge_seen.has_key?(doc_id)

    title = DiligenceCore._or(data["title"]?.try(&.as_s?), "Untitled Document")
    url = data["url"]?.try(&.as_s?)
    summary = DiligenceCore._or(data["summary"]?.try(&.as_s?), "")
    company_id = data["company_id"]?.try(&.as_s?)
    published_at = data["published_at"]?.try(&.as_s?)

    begin
      src = graph.add_object("source", {
        "kind"     => JSON::Any.new("document"),
        "content"  => JSON::Any.new(summary),
        "url"      => url.nil? ? JSON::Any.new(nil) : JSON::Any.new(url),
        "metadata" => JSON::Any.new({
          "title"                 => JSON::Any.new(title),
          "company_id"            => company_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(company_id),
          "published_at"          => published_at.nil? ? JSON::Any.new(nil) : JSON::Any.new(published_at),
          "diligence_document_id" => JSON::Any.new(doc_id),
          "bridge"                => JSON::Any.new("diligence_core"),
        }),
      }.to_json, actor: "bridges.document_to_source")
      DiligenceCore.bridge_seen[doc_id] = src.id
      begin
        graph.add_relation(src.id, doc_id, "derived_from", actor: "bridges.document_to_source")
      rescue
      end
    rescue
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # claim  →  observation
  # ──────────────────────────────────────────────────────────────────────────

  # Map a Diligence claim to a Core observation.
  #
  # Diligence claim fields: text, confidence, company_id, source_document_id, status
  # Core observation fields: text, confidence, category, source_ids, metadata
  @[Chronicle::Packs::Annotations::Behavior(name: "claim_to_observation", on: ["object.created"], where: {"type" => "claim"}, creates: ["observation"])]
  def claim_to_observation(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    claim_id, data = DiligenceCore._payload(event)
    return if claim_id.nil? || DiligenceCore.bridge_seen.has_key?(claim_id)

    text = DiligenceCore._or(data["text"]?.try(&.as_s?), "")
    return if text.empty?

    confidence = data["confidence"]?.try(&.as_f?)
    confidence = confidence.nil? || confidence == 0.0 ? 0.75 : confidence
    company_id = data["company_id"]?.try(&.as_s?)
    source_doc_id = data["source_document_id"]?.try(&.as_s?)
    status = DiligenceCore._or(data["status"]?.try(&.as_s?), "unverified")

    source_ids = [] of String
    if source_doc_id && DiligenceCore.bridge_seen.has_key?(source_doc_id)
      source_ids = [DiligenceCore.bridge_seen[source_doc_id]]
    end

    begin
      obs = graph.add_object("observation", {
        "text"           => JSON::Any.new(text),
        "confidence"     => JSON::Any.new(confidence),
        "low_confidence" => JSON::Any.new(confidence < 0.5),
        "source_ids"     => JSON::Any.new(source_ids.map { |id| JSON::Any.new(id) }),
        "category"       => JSON::Any.new("fact"),
        "metadata"       => JSON::Any.new({
          "company_id"             => company_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(company_id),
          "diligence_claim_id"     => JSON::Any.new(claim_id),
          "diligence_claim_status" => JSON::Any.new(status),
          "bridge"                 => JSON::Any.new("diligence_core"),
        }),
      }.to_json, actor: "bridges.claim_to_observation")
      DiligenceCore.bridge_seen[claim_id] = obs.id
      begin
        graph.add_relation(obs.id, claim_id, "derived_from", actor: "bridges.claim_to_observation")
      rescue
      end
      source_ids.each do |sid|
        graph.add_relation(sid, obs.id, "grounds", actor: "bridges.claim_to_observation")
      rescue
      end
    rescue
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # memo  →  artifact
  # ──────────────────────────────────────────────────────────────────────────

  # Map a Diligence memo to a Core artifact.
  #
  # Diligence memo fields: company_id, summary, thesis_questions_addressed,
  #                        key_claims, open_contradictions, risks
  # Core artifact fields: kind, title, content, format, status, metadata
  @[Chronicle::Packs::Annotations::Behavior(name: "memo_to_artifact", on: ["object.created"], where: {"type" => "memo"}, creates: ["artifact"])]
  def memo_to_artifact(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    memo_id, data = DiligenceCore._payload(event)
    return if memo_id.nil? || DiligenceCore.bridge_seen.has_key?(memo_id)

    company_id = DiligenceCore._or(data["company_id"]?.try(&.as_s?), "unknown")
    summary = DiligenceCore._or(data["summary"]?.try(&.as_s?), "")
    key_claims = data["key_claims"]?.try(&.as_a) || [] of JSON::Any
    thesis_qs = data["thesis_questions_addressed"]?.try(&.as_a) || [] of JSON::Any
    open_contras = data["open_contradictions"]?.try(&.as_a) || data["contradictions_note"]?.try(&.as_a) || [] of JSON::Any
    risks = data["risks"]?.try(&.as_a) || [] of JSON::Any

    content = DiligenceCore._memo_content(company_id, summary, key_claims, thesis_qs, open_contras, risks)

    begin
      art = graph.add_object("artifact", {
        "kind"     => JSON::Any.new("memo"),
        "title"    => JSON::Any.new("Diligence Memo: #{company_id}"),
        "content"  => JSON::Any.new(content),
        "format"   => JSON::Any.new("markdown"),
        "status"   => JSON::Any.new("draft"),
        "metadata" => JSON::Any.new({
          "company_id"        => JSON::Any.new(company_id),
          "diligence_memo_id" => JSON::Any.new(memo_id),
          "bridge"            => JSON::Any.new("diligence_core"),
        }),
      }.to_json, actor: "bridges.memo_to_artifact")
      DiligenceCore.bridge_seen[memo_id] = art.id
      begin
        graph.add_relation(art.id, memo_id, "derived_from", actor: "bridges.memo_to_artifact")
      rescue
      end
    rescue
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # risk  →  evaluation
  # ──────────────────────────────────────────────────────────────────────────

  # Map a Diligence risk to a Core evaluation.
  #
  # Diligence risk fields: title, description, severity, company_id, related_claim_ids
  # Core evaluation fields: subject_id, subject_type, judgment, rationale, metadata
  @[Chronicle::Packs::Annotations::Behavior(name: "risk_to_evaluation", on: ["object.created"], where: {"type" => "risk"}, creates: ["evaluation"])]
  def risk_to_evaluation(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext) : Nil
    risk_id, data = DiligenceCore._payload(event)
    return if risk_id.nil? || DiligenceCore.bridge_seen.has_key?(risk_id)

    title = DiligenceCore._or(data["title"]?.try(&.as_s?), "Unspecified Risk")
    description = DiligenceCore._or(data["description"]?.try(&.as_s?), "")
    severity = DiligenceCore._or(data["severity"]?.try(&.as_s?), "medium")
    company_id = data["company_id"]?.try(&.as_s?)
    related_claim_ids = data["related_claim_ids"]?.try(&.as_a) || [] of JSON::Any

    rationale = description.empty? ? title : "#{title}: #{description}"

    begin
      evl = graph.add_object("evaluation", {
        "subject_id"   => JSON::Any.new(risk_id),
        "subject_type" => JSON::Any.new("risk"),
        "judgment"     => JSON::Any.new(severity),
        "rationale"    => JSON::Any.new(rationale),
        "evaluator"    => JSON::Any.new("diligence_core_bridge"),
        "metadata"     => JSON::Any.new({
          "company_id"        => company_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(company_id),
          "diligence_risk_id" => JSON::Any.new(risk_id),
          "related_claim_ids" => JSON::Any.new(related_claim_ids),
          "bridge"            => JSON::Any.new("diligence_core"),
        }),
      }.to_json, actor: "bridges.risk_to_evaluation")
      DiligenceCore.bridge_seen[risk_id] = evl.id
      begin
        graph.add_relation(evl.id, risk_id, "derived_from", actor: "bridges.risk_to_evaluation")
      rescue
      end
    rescue
    end
  end
end

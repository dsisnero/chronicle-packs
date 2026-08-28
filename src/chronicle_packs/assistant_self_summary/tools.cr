require "json"
require "digest"

module Chronicle::Packs::AssistantSelfSummary
  # Ingest one assistant self-summary as strict normalizer handoffs. Ported
  # from upstream packs/importers/assistant_self_summary/tools.py.
  #
  # Identity rule (ADR 0025): the dedup key is the SHA-256 of the canonical
  # summary text, so the same summary pasted (manual) or pushed (mcp) lands
  # on one evidence identity. The text is untrusted external content:
  # `scan_for_injection` labels land in the normalized metadata (auditable,
  # queryable) and the pipeline structure keeps a hostile summary inert —
  # evidence → annotations → candidates, nothing that acts, approves, or
  # escalates.
  module ImportConstants
    IMPORTER_ID        = "assistant_self_summary"
    IMPORTER_VERSION   = "0.1.0"
    DEFAULT_SURFACE_ID = "assistant_self_summary"
    TRANSPORTS         = Set{"manual", "mcp"}
  end

  # The transport-independent canonical form of a pasted summary.
  #
  # Conservative on purpose: newline normalization and outer whitespace only,
  # so cosmetic copy/paste differences collapse while distinct summaries stay
  # distinct.
  def self.canonical_summary_text(text : String) : String
    text.gsub("\r\n", "\n").gsub("\r", "\n").strip
  end

  def self._sha256(payload : String) : String
    Digest::SHA256.hexdigest(payload)
  end

  def self._record_failure(
    graph : Chronicle::GraphProjection,
    *,
    source_surface_id : String,
    error_code : String,
    message : String,
    metadata : Hash(String, JSON::Any)? = nil,
  ) : String
    failure = graph.add_object("ingestion_failure", {
      "source_surface_id" => JSON::Any.new(source_surface_id),
      "acquired_item_id"  => JSON::Any.new(nil),
      "source_ref"        => JSON::Any.new("#{ImportConstants::IMPORTER_ID}:submission"),
      "stage"             => JSON::Any.new("acquisition"),
      "error_code"        => JSON::Any.new(error_code),
      "message"           => JSON::Any.new(message[0, 500]),
      "importer_id"       => JSON::Any.new(ImportConstants::IMPORTER_ID),
      "importer_version"  => JSON::Any.new(ImportConstants::IMPORTER_VERSION),
      "extractor_id"      => JSON::Any.new(nil),
      "extractor_version" => JSON::Any.new(nil),
      "recoverable"       => JSON::Any.new(false),
      "metadata"          => JSON::Any.new(metadata || {} of String => JSON::Any),
    }.to_json, actor: "assistant_self_summary.acquisition")
    failure.id
  end

  # Acquire one self-summary submission.
  #
  # Re-submission of the same canonical text (any transport) re-emits an
  # acquisition record by design; the normalizer owns evidence identity and
  # dedups it to zero new revisions.
  def self.import_assistant_self_summary_fn(
    graph : Chronicle::GraphProjection,
    text : String,
    *,
    transport : String = "manual",
    source_surface_id : String = ImportConstants::DEFAULT_SURFACE_ID,
    assistant_name : String? = nil,
    provider_time : String? = nil,
    is_fixture : Bool = false,
    max_summary_chars : Int32 = 64_000,
    max_normalized_chars : Int32 = 32_000,
  ) : Hash(String, JSON::Any)
    unless ImportConstants::TRANSPORTS.includes?(transport)
      raise PackError.new("transport must be one of #{ImportConstants::TRANSPORTS.to_a.sort}, got #{transport.inspect}")
    end

    canonical = canonical_summary_text(text || "")
    if canonical.empty?
      return {
        "ok"          => JSON::Any.new(false),
        "imported"    => JSON::Any.new(0),
        "failure_ids" => JSON::Any.new([
          JSON::Any.new(_record_failure(
            graph,
            source_surface_id: source_surface_id,
            error_code: "empty_summary",
            message: "self-summary is empty after canonicalization",
            metadata: {"transport" => JSON::Any.new(transport)},
          )),
        ]),
      }
    end
    if canonical.size > max_summary_chars
      return {
        "ok"          => JSON::Any.new(false),
        "imported"    => JSON::Any.new(0),
        "failure_ids" => JSON::Any.new([
          JSON::Any.new(_record_failure(
            graph,
            source_surface_id: source_surface_id,
            error_code: "summary_too_large",
            message: "self-summary is #{canonical.size} chars; limit is #{max_summary_chars}",
            metadata: {"transport" => JSON::Any.new(transport), "chars" => JSON::Any.new(canonical.size)},
          )),
        ]),
      }
    end

    content_hash = _sha256(canonical)
    dedup_key = "self_summary:#{content_hash}"
    injection_flags = ToolGateway::Untrusted.scan_for_injection(canonical)

    acquired = graph.add_object("acquired_item", {
      "source_surface_id" => JSON::Any.new(source_surface_id),
      "provider_item_id"  => JSON::Any.new(dedup_key),
      "dedup_key"         => JSON::Any.new(dedup_key),
      "source_ref"        => JSON::Any.new("#{ImportConstants::IMPORTER_ID}:#{transport}:#{content_hash[0, 12]}"),
      "source_hash"       => JSON::Any.new(content_hash),
      "provider_time"     => provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil),
      # Pasted text is ephemeral unique content — inline replay is the
      # sanctioned mode (ADR 0013/0015); the payload IS the ref.
      "replay_mode"         => JSON::Any.new("inline"),
      "replay_payload_ref"  => JSON::Any.new(canonical),
      "replay_payload_hash" => JSON::Any.new(content_hash),
      "media_type"          => JSON::Any.new("text/markdown"),
      "importer_id"         => JSON::Any.new(ImportConstants::IMPORTER_ID),
      "importer_version"    => JSON::Any.new(ImportConstants::IMPORTER_VERSION),
    }.to_json, actor: "assistant_self_summary.acquisition")
    graph.add_object("acquired_content", {
      "acquired_item_id"    => JSON::Any.new(acquired.id),
      "normalized_content"  => JSON::Any.new(canonical[0, max_normalized_chars]),
      "normalized_metadata" => JSON::Any.new({
        "subject_scope"   => JSON::Any.new("owner_profile"),
        "seed_kind"       => JSON::Any.new("self_summary"),
        "transport"       => JSON::Any.new(transport),
        "assistant_name"  => assistant_name ? JSON::Any.new(assistant_name) : JSON::Any.new(nil),
        "role"            => JSON::Any.new("assistant"),
        "injection_flags" => JSON::Any.new(injection_flags.map { |flag| JSON::Any.new(flag) }),
        "char_count"      => JSON::Any.new(canonical.size),
        "truncated"       => JSON::Any.new(canonical.size > max_normalized_chars),
      }),
      "source_category" => JSON::Any.new("ai_activity"),
      "connection_path" => JSON::Any.new(transport),
      "is_fixture"      => JSON::Any.new(is_fixture),
    }.to_json, actor: "assistant_self_summary.acquisition")
    {
      "ok"               => JSON::Any.new(true),
      "imported"         => JSON::Any.new(1),
      "acquired_item_id" => JSON::Any.new(acquired.id),
      "dedup_key"        => JSON::Any.new(dedup_key),
      "content_hash"     => JSON::Any.new(content_hash),
      "transport"        => JSON::Any.new(transport),
      "injection_flags"  => JSON::Any.new(injection_flags.map { |flag| JSON::Any.new(flag) }),
      "failure_ids"      => JSON::Any.new([] of JSON::Any),
    }
  end

  # Registered capability wrapper for import_assistant_self_summary_fn.
  @[Chronicle::Packs::Annotations::Tool(name: "import_assistant_self_summary", description: "Ingest one assistant self-summary (pasted or MCP-pushed). The same text through either transport lands on one evidence identity; the text is injection-scanned untrusted content.")]
  def import_assistant_self_summary_tool(args : String) : String
    input = JSON.parse(args).as_h
    graph = bound_graph_or_raise
    result = import_assistant_self_summary_fn(
      graph,
      input["text"]?.try(&.as_s?) || "",
      transport: input["transport"]?.try(&.as_s?) || "manual",
      source_surface_id: input["source_surface_id"]?.try(&.as_s?) || ImportConstants::DEFAULT_SURFACE_ID,
      assistant_name: input["assistant_name"]?.try(&.as_s?),
      provider_time: input["provider_time"]?.try(&.as_s?),
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
      max_summary_chars: input["max_summary_chars"]?.try(&.as_i?) || 64_000,
      max_normalized_chars: input["max_normalized_chars"]?.try(&.as_i?) || 32_000,
    )
    result.to_json
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "assistant_self_summary tools require a bound graph (set AssistantSelfSummary.bound_graph)"
    )
  end
end

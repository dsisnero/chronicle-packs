require "json"
require "digest"
require "file_utils"
require "compress/zip"
require "time"

module Chronicle::Packs::ClaudeExport
  # Bounded parser for official Claude data-export snapshots. Ported from
  # upstream packs/importers/claude_export/tools.py.
  #
  # conversations.json is a flat list of conversations, each carrying an
  # ordered chat_messages transcript — unlike the ChatGPT export there is no
  # branch tree. Every message becomes one acquired-item/content pair. The
  # export arrives either as the official ZIP archive or as a bare
  # conversations.json file; both are accepted and detected by extension and
  # magic bytes.
  module ImportConstants
    IMPORTER_ID          = "claude_export"
    IMPORTER_VERSION     = "0.1.0"
    CONVERSATIONS_MEMBER = "conversations.json"
    # ZIP local-file-header signature bytes (PK\x03\x04), as a LE UInt32.
    ZIP_MAGIC_LE            = 0x04034b50_u32
    REPLAY_MODES            = Set{"inline", "artifact", "reference_only"}
    REFERENCE_ONLY_SENTINEL = "reference_only:no-payload"
  end

  # A bounded, user-visible export parsing failure.
  class ExportFormatError < Exception
  end

  def self._sha256(payload : Bytes | String) : String
    Digest::SHA256.hexdigest(payload)
  end

  # Canonical compact JSON (upstream `_canonical_json`: ensure_ascii=False,
  # sort_keys=True, separators=(",", ":")).
  def self._canonical_json(value : JSON::Any) : String
    _canonical_any(value)
  end

  private def self._canonical_any(value : JSON::Any) : String
    case raw = value.raw
    when Hash(String, JSON::Any)
      keys = raw.keys.sort!
      JSON.build do |json|
        json.object do
          keys.each { |k| json.field(k, raw[k]) }
        end
      end
    when Array
      JSON.build do |json|
        json.array do
          raw.each { |item| json.raw(_canonical_any(item)) }
        end
      end
    else
      value.to_json
    end
  end

  # Append one bounded acquisition failure and return its graph id.
  def self._record_failure(
    graph : Chronicle::GraphProjection,
    *,
    source_surface_id : String?,
    source_ref : String?,
    error_code : String,
    message : String,
    recoverable : Bool = false,
    metadata : Hash(String, JSON::Any)? = nil,
  ) : String
    failure = graph.add_object("ingestion_failure", {
      "source_surface_id" => source_surface_id ? JSON::Any.new(source_surface_id) : JSON::Any.new(nil),
      "acquired_item_id"  => JSON::Any.new(nil),
      "source_ref"        => source_ref ? JSON::Any.new(source_ref) : JSON::Any.new(nil),
      "stage"             => JSON::Any.new("acquisition"),
      "error_code"        => JSON::Any.new(error_code),
      "message"           => JSON::Any.new(message[0, 500]),
      "importer_id"       => JSON::Any.new(ImportConstants::IMPORTER_ID),
      "importer_version"  => JSON::Any.new(ImportConstants::IMPORTER_VERSION),
      "extractor_id"      => JSON::Any.new(nil),
      "extractor_version" => JSON::Any.new(nil),
      "recoverable"       => JSON::Any.new(recoverable),
      "metadata"          => JSON::Any.new(metadata || {} of String => JSON::Any),
    }.to_json, actor: "claude_export.acquisition")
    failure.id
  end

  # Atomically retain exact replay bytes in the shared v0 CAS layout.
  def self._artifact_ref(payload : Bytes, artifact_store_dir : String) : {String, String}
    digest = _sha256(payload)
    root = Path.new(artifact_store_dir).expand(home: true).expand
    target = root / "sha256" / digest[0, 2] / digest
    FileUtils.mkdir_p(target.parent)
    if File.exists?(target)
      if File.symlink?(target) || !File.file?(target) || _sha256(File.open(target, "rb", &.gets_to_end.to_slice)) != digest
        raise PackError.new("artifact collision or corruption at #{target}")
      end
    else
      tmp_name = target.parent / ".#{digest}.#{Random::Secure.hex(4)}"
      begin
        File.open(tmp_name, "wb", &.write(payload))
        File.rename(tmp_name, target)
      ensure
        File.delete(tmp_name) if File.exists?(tmp_name)
      end
    end
    {"artifact://sha256/#{digest[0, 2]}/#{digest}", digest}
  end

  def self._replay_reference(payload : String, *, replay_mode : String, artifact_store_dir : String) : {String, String}
    encoded = payload.to_slice
    digest = _sha256(encoded)
    if replay_mode == "inline"
      return {payload, digest}
    end
    if replay_mode == "reference_only"
      return {ImportConstants::REFERENCE_ONLY_SENTINEL, digest}
    end
    _artifact_ref(encoded, artifact_store_dir)
  end

  # Parse a provider timestamp: numeric epoch seconds or an ISO string.
  def self._provider_time(value : JSON::Any?) : String?
    return nil if value.nil? || value.raw.is_a?(Bool)
    case raw = value.raw
    when Int32, Int64
      _iso_from_epoch(raw.to_i64)
    when Float32, Float64
      _iso_from_epoch(raw.to_f64)
    when String
      s = raw.strip
      s.empty? ? nil : s
    else
      nil
    end
  end

  private def self._iso_from_epoch(seconds : Float64) : String?
    return nil unless seconds.finite?
    begin
      Time.unix(seconds.to_i64).to_utc.to_s("%Y-%m-%dT%H:%M:%S%:z")
    rescue
      nil
    end
  end

  private def self._iso_from_epoch(seconds : Int64) : String?
    Time.unix(seconds).to_utc.to_s("%Y-%m-%dT%H:%M:%S%:z")
  rescue
    nil
  end

  # Extract the text of one content block.
  def self._block_text(block : JSON::Any?) : String
    return "" if block.nil?
    case raw = block.raw
    when String
      raw
    when Int32, Int64, Float32, Float64, Bool
      raw.to_s
    when Nil
      ""
    when Hash(String, JSON::Any)
      block_type = raw["type"]?.try(&.as_s?)
      if text_val = raw["text"]?
        if (block_type.nil? || block_type == "text") && text_val.raw.is_a?(String)
          return text_val.as_s
        end
      end
      kind = block_type.nil? || block_type.empty? ? "non_text" : block_type
      "[#{kind} content omitted]"
    else
      ""
    end
  end

  # Normalize one message's content to bounded text + metadata.
  #
  # Prefer typed content blocks; fall back to the legacy plain `text`.
  def self._normalized_message(message : JSON::Any, max_chars : Int32) : {String, Hash(String, JSON::Any)}
    m = message.as_h
    content = m["content"]?
    blocks = [] of JSON::Any
    content_source = "content_blocks"
    if content && content.raw.is_a?(Array)
      blocks = content.as_a
    elsif content && content.raw.is_a?(String)
      blocks = [content]
    elsif content && !content.raw.nil?
      blocks = [content]
    elsif text_field = m["text"]?
      if text_field.raw.is_a?(String)
        blocks = [text_field]
        content_source = "text_field"
      else
        content_source = "empty"
      end
    else
      content_source = "empty"
    end

    text = blocks.compact_map { |block| _block_text(block) }.reject(&.empty?).join("\n")
    text = text.gsub("\r\n", "\n").gsub("\r", "\n")
    original_chars = text.size
    truncated = original_chars > max_chars
    if truncated
      text = text[0, max_chars]
    end
    meta = {} of String => JSON::Any
    meta["content_source"] = JSON::Any.new(content_source)
    meta["block_count"] = JSON::Any.new(blocks.size)
    meta["normalized_char_count"] = JSON::Any.new(original_chars)
    meta["truncated"] = JSON::Any.new(truncated)
    {text, meta}
  end

  # Validate one whole conversation, then build all of its message records.
  # Any structural problem raises before a single record is returned, so a
  # malformed conversation never partially emits.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _conversation_records
  def self._conversation_records(conversation : JSON::Any, *, max_messages_per_conversation : Int32, max_normalized_chars : Int32) : Array(Hash(String, JSON::Any))
    if !conversation.raw.is_a?(Hash(String, JSON::Any))
      raise ExportFormatError.new("conversation entry is not an object")
    end
    conv = conversation.as_h
    conversation_uuid = conv["uuid"]?.try(&.as_s?) || ""
    if conversation_uuid.empty?
      raise ExportFormatError.new("conversation has no stable uuid")
    end
    messages = conv["chat_messages"]?
    messages = JSON::Any.new([] of JSON::Any) if messages.nil?
    if !messages.raw.is_a?(Array)
      raise ExportFormatError.new("conversation #{conversation_uuid.inspect} chat_messages is not a list")
    end
    messages_arr = messages.as_a
    if messages_arr.size > max_messages_per_conversation
      raise ExportFormatError.new("conversation #{conversation_uuid.inspect} has #{messages_arr.size} messages; limit is #{max_messages_per_conversation}")
    end

    name = conv["name"]?.try(&.as_s?)
    seen_uuids = Set(String).new
    records = [] of Hash(String, JSON::Any)
    messages_arr.each_with_index do |message, index|
      if !message.raw.is_a?(Hash(String, JSON::Any))
        raise ExportFormatError.new("conversation #{conversation_uuid.inspect} message at index #{index} is not an object")
      end
      m = message.as_h
      message_uuid = m["uuid"]?.try(&.as_s?) || ""
      if message_uuid.empty?
        raise ExportFormatError.new("conversation #{conversation_uuid.inspect} message at index #{index} has no stable uuid")
      end
      if seen_uuids.includes?(message_uuid)
        raise ExportFormatError.new("conversation #{conversation_uuid.inspect} has duplicate message uuid #{message_uuid.inspect}")
      end
      seen_uuids << message_uuid

      text, content_meta = _normalized_message(message, max_normalized_chars)
      sender = m["sender"]?.try(&.as_s?)
      role = {"human" => "user", "assistant" => "assistant"}[sender]? || sender
      provider_time = _provider_time(
        m["created_at"]? || m["updated_at"]? || conv["updated_at"]? || conv["created_at"]?
      )

      normalized_metadata = {} of String => JSON::Any
      normalized_metadata["conversation_uuid"] = JSON::Any.new(conversation_uuid)
      normalized_metadata["conversation_name"] = name ? JSON::Any.new(name) : JSON::Any.new(nil)
      normalized_metadata["message_uuid"] = JSON::Any.new(message_uuid)
      normalized_metadata["message_index"] = JSON::Any.new(index)
      normalized_metadata["sender"] = sender ? JSON::Any.new(sender) : JSON::Any.new(nil)
      normalized_metadata["role"] = role ? JSON::Any.new(role) : JSON::Any.new(nil)
      normalized_metadata["provider_time"] = provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
      content_meta.each { |k, v| normalized_metadata[k] = v }

      replay_unit = {} of String => JSON::Any
      replay_unit["conversation_uuid"] = JSON::Any.new(conversation_uuid)
      replay_unit["conversation_name"] = name ? JSON::Any.new(name) : JSON::Any.new(nil)
      replay_unit["message_uuid"] = JSON::Any.new(message_uuid)
      replay_unit["message_index"] = JSON::Any.new(index)
      replay_unit["sender"] = sender ? JSON::Any.new(sender) : JSON::Any.new(nil)
      replay_unit["provider_time"] = provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
      replay_unit["normalized_content"] = JSON::Any.new(text)
      replay_unit["normalized_metadata"] = JSON::Any.new(normalized_metadata)

      records << {
        "conversation_uuid"   => JSON::Any.new(conversation_uuid),
        "message_uuid"        => JSON::Any.new(message_uuid),
        "dedup_key"           => JSON::Any.new("#{conversation_uuid}:#{message_uuid}"),
        "provider_item_id"    => JSON::Any.new("#{conversation_uuid}:#{message_uuid}"),
        "provider_time"       => provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil),
        "source_hash"         => JSON::Any.new(_sha256(_canonical_json(message).to_slice)),
        "normalized_content"  => JSON::Any.new(text),
        "normalized_metadata" => JSON::Any.new(normalized_metadata),
        "replay_payload"      => JSON::Any.new(_canonical_json(JSON::Any.new(replay_unit))),
        "sender"              => sender ? JSON::Any.new(sender) : JSON::Any.new(nil),
      }
    end
    records
  end

  # Read the conversations.json root from a ZIP or bare JSON file.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _read_conversations
  def self._read_conversations(export_path : String, *, max_archive_bytes : Int64, max_json_bytes : Int64, max_compression_ratio : Int32) : {Path, String, Array(JSON::Any)}
    source = Path.new(export_path).expand(home: true)
    if File.symlink?(source) || !File.file?(source)
      raise ExportFormatError.new("export_path must be an existing, non-symlink ZIP or conversations.json file")
    end
    size = File.size(source)
    if size > max_archive_bytes
      raise ExportFormatError.new("export is #{size} bytes; limit is #{max_archive_bytes}")
    end
    source = source.expand
    magic = File.open(source, "rb") { |io| io.read_bytes(UInt32, format: IO::ByteFormat::LittleEndian) }
    is_zip = source.extension.downcase == ".zip" || magic == ImportConstants::ZIP_MAGIC_LE

    raw : String? = nil
    kind = "json"
    if is_zip
      begin
        Compress::Zip::File.open(source) do |zip|
          entry = zip["conversations.json"]?
          if entry.nil?
            raise ExportFormatError.new("archive has no root conversations.json")
          end
          if (entry.general_purpose_bit_flag & 0x1) != 0
            raise ExportFormatError.new("encrypted conversations.json is unsupported")
          end
          if entry.uncompressed_size > max_json_bytes
            raise ExportFormatError.new("conversations.json is #{entry.uncompressed_size} bytes; limit is #{max_json_bytes}")
          end
          if entry.uncompressed_size > 0 && entry.uncompressed_size / Math.max(1, entry.compressed_size) > max_compression_ratio
            raise ExportFormatError.new("conversations.json exceeds compression-ratio bound")
          end
          IO::Memory.new.tap do |io|
            entry.open { |entry_io| IO.copy(entry_io, io) }
            raw = io.to_s
          end
        end
      rescue ex : Compress::Zip::Error
        raise ExportFormatError.new("archive is not a valid ZIP file")
      end
      kind = "zip"
    else
      if size > max_json_bytes
        raise ExportFormatError.new("conversations.json is #{size} bytes; limit is #{max_json_bytes}")
      end
      raw = File.open(source, "rb", &.gets_to_end)
      kind = "json"
    end
    if raw.nil?
      raise ExportFormatError.new("conversations.json is empty or unreadable")
    end
    parsed = begin
      JSON.parse(raw.to_s.lstrip("\uFEFF"))
    rescue ex : JSON::ParseException
      raise ExportFormatError.new("malformed conversations.json: #{ex.message}")
    end
    if !parsed.raw.is_a?(Array)
      raise ExportFormatError.new("conversations.json root must be a list")
    end
    {source, kind, parsed.as_a}
  end

  def self._find_cursor(graph : Chronicle::GraphProjection, source_surface_id : String) : Chronicle::GraphObject?
    graph.objects(type: "backfill_cursor").each do |cursor|
      if JSON.parse(cursor.data)["source_surface_id"]?.try(&.as_s?) == source_surface_id
        return cursor
      end
    end
    nil
  end

  # Commit stable progress after each fully recorded acquired item.
  def self._advance_cursor(graph : Chronicle::GraphProjection, cursor : Chronicle::GraphObject?, source_surface_id : String, stable_ref : String) : Chronicle::GraphObject
    if cursor.nil?
      return graph.add_object("backfill_cursor", {
        "source_surface_id"   => JSON::Any.new(source_surface_id),
        "oldest_ingested_ref" => JSON::Any.new(stable_ref),
        "newest_ingested_ref" => JSON::Any.new(stable_ref),
        "cursor_version"      => JSON::Any.new(1),
      }.to_json, actor: "claude_export.acquisition")
    end
    data = JSON.parse(cursor.data).as_h
    oldest = data["oldest_ingested_ref"]?.try(&.as_s?)
    newest = data["newest_ingested_ref"]?.try(&.as_s?)
    new_oldest = oldest ? [oldest, stable_ref].min : stable_ref
    new_newest = newest ? [newest, stable_ref].max : stable_ref
    obj = graph.get_object(cursor.id)
    current = obj ? JSON.parse(obj.data).as_h : data
    current["oldest_ingested_ref"] = JSON::Any.new(new_oldest)
    current["newest_ingested_ref"] = JSON::Any.new(new_newest)
    current["cursor_version"] = JSON::Any.new(1)
    graph.patch_object(cursor.id, current.to_json, actor: "claude_export.acquisition")
    graph.get_object(cursor.id) || raise PackError.new("cursor #{cursor.id} vanished")
  end

  # URL-encode a path segment (upstream urllib.parse.quote).
  def self._quote(value : String) : String
    value.gsub(/[^A-Za-z0-9_\-.]/) do |char|
      "%" + char.bytes.map(&.to_s(16).upcase.rjust(2, '0')).join
    end
  end

  # Acquire one bounded official Claude export snapshot (ZIP or bare JSON).
  #
  # A malformed conversation is validated before any of its message objects
  # are emitted. Valid sibling conversations remain committed. Re-import and
  # snapshot overlap intentionally re-emit acquired records; the normalizer
  # owns evidence identity and deduplication.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream import_claude_export_fn
  def self.import_claude_export_fn(
    graph : Chronicle::GraphProjection,
    export_path : String,
    source_surface_id : String,
    *,
    artifact_store_dir : String = ".activegraph/replay-artifacts",
    replay_mode : String = "artifact",
    is_fixture : Bool = false,
    max_archive_bytes : Int64 = 1_000_000_000,
    max_conversations_json_bytes : Int64 = 256_000_000,
    max_compression_ratio : Int32 = 200,
    max_conversations : Int32 = 10_000,
    max_messages_per_conversation : Int32 = 10_000,
    max_messages : Int32 = 250_000,
    max_normalized_chars : Int32 = 32_000,
  ) : Hash(String, JSON::Any)
    unless ImportConstants::REPLAY_MODES.includes?(replay_mode)
      raise PackError.new("unsupported replay_mode #{replay_mode.inspect}")
    end
    if source_surface_id.empty?
      raise PackError.new("source_surface_id is required")
    end
    bounds = [max_archive_bytes, max_conversations_json_bytes, max_compression_ratio.to_i64, max_conversations.to_i64, max_messages_per_conversation.to_i64, max_messages.to_i64, max_normalized_chars.to_i64]
    if bounds.any? { |v| v < 1 }
      raise PackError.new("all import bounds must be positive")
    end

    acquired_item_ids = [] of String
    failure_ids = [] of String
    human_count = 0
    assistant_count = 0
    conversation_count = 0
    stopped_at_bound = false
    cursor = _find_cursor(graph, source_surface_id)

    begin
      source, input_kind, conversations = _read_conversations(
        export_path,
        max_archive_bytes: max_archive_bytes,
        max_json_bytes: max_conversations_json_bytes,
        max_compression_ratio: max_compression_ratio,
      )
    rescue ex : ExportFormatError | IO::Error
      failure_ids << _record_failure(
        graph,
        source_surface_id: source_surface_id,
        source_ref: Path.new(export_path).expand(home: true).to_s,
        error_code: "invalid_export",
        message: ex.message.to_s,
        recoverable: ex.is_a?(IO::Error),
      )
      return {
        "ok"                 => JSON::Any.new(false),
        "imported"           => JSON::Any.new(0),
        "failed"             => JSON::Any.new(1),
        "conversations"      => JSON::Any.new(0),
        "human_messages"     => JSON::Any.new(0),
        "assistant_messages" => JSON::Any.new(0),
        "cursor_id"          => cursor ? JSON::Any.new(cursor.id) : JSON::Any.new(nil),
        "acquired_item_ids"  => JSON::Any.new([] of JSON::Any),
        "failure_ids"        => JSON::Any.new([] of JSON::Any),
        "stopped_at_bound"   => JSON::Any.new(false),
      }
    end

    source_base = input_kind == "zip" ? "#{source}!/#{ImportConstants::CONVERSATIONS_MEMBER}" : source.to_s
    if conversations.size > max_conversations
      stopped_at_bound = true
      failure_ids << _record_failure(
        graph,
        source_surface_id: source_surface_id,
        source_ref: source_base,
        error_code: "conversation_bound_reached",
        message: "export has #{conversations.size} conversations; limit is #{max_conversations}",
        recoverable: true,
        metadata: {"available" => JSON::Any.new(conversations.size), "limit" => JSON::Any.new(max_conversations)},
      )
    end
    conversations.first(max_conversations).each_with_index do |conversation, index|
      raw_uuid = conversation.raw.is_a?(Hash(String, JSON::Any)) ? conversation.as_h["uuid"]?.try(&.as_s?) : nil
      conversation_ref = "#{source_base}#conversation=#{_quote(raw_uuid || index.to_s)}"
      begin
        records = _conversation_records(
          conversation,
          max_messages_per_conversation: max_messages_per_conversation,
          max_normalized_chars: max_normalized_chars,
        )
      rescue ex : ExportFormatError
        failure_ids << _record_failure(
          graph,
          source_surface_id: source_surface_id,
          source_ref: conversation_ref,
          error_code: "invalid_conversation",
          message: ex.message.to_s,
          metadata: {"conversation_index" => JSON::Any.new(index), "conversation_uuid" => raw_uuid ? JSON::Any.new(raw_uuid) : JSON::Any.new(nil)},
        )
        next
      end
      if acquired_item_ids.size + records.size > max_messages
        stopped_at_bound = true
        failure_ids << _record_failure(
          graph,
          source_surface_id: source_surface_id,
          source_ref: conversation_ref,
          error_code: "message_bound_reached",
          message: "conversation would exceed message limit #{max_messages}; conversation was not partially emitted",
          recoverable: true,
          metadata: {"conversation_index" => JSON::Any.new(index), "message_count" => JSON::Any.new(records.size)},
        )
        break
      end

      conversation_count += 1
      records.each do |record|
        source_ref = "#{source_base}#conversation=#{_quote(record["conversation_uuid"].as_s)}&message=#{_quote(record["message_uuid"].as_s)}"
        begin
          replay_ref, replay_hash = _replay_reference(
            record["replay_payload"].as_s,
            replay_mode: replay_mode,
            artifact_store_dir: artifact_store_dir,
          )
        rescue ex : IO::Error
          failure_ids << _record_failure(
            graph,
            source_surface_id: source_surface_id,
            source_ref: source_ref,
            error_code: "artifact_write_failed",
            message: ex.message.to_s,
            recoverable: true,
            metadata: {"provider_item_id" => JSON::Any.new(record["provider_item_id"].as_s)},
          )
          next
        end

        acquired = graph.add_object("acquired_item", {
          "source_surface_id"   => JSON::Any.new(source_surface_id),
          "provider_item_id"    => JSON::Any.new(record["provider_item_id"].as_s),
          "dedup_key"           => JSON::Any.new(record["dedup_key"].as_s),
          "source_ref"          => JSON::Any.new(source_ref),
          "source_hash"         => JSON::Any.new(record["source_hash"].as_s),
          "provider_time"       => record["provider_time"],
          "replay_mode"         => JSON::Any.new(replay_mode),
          "replay_payload_ref"  => JSON::Any.new(replay_ref),
          "replay_payload_hash" => JSON::Any.new(replay_hash),
          "media_type"          => JSON::Any.new("application/json"),
          "importer_id"         => JSON::Any.new(ImportConstants::IMPORTER_ID),
          "importer_version"    => JSON::Any.new(ImportConstants::IMPORTER_VERSION),
        }.to_json, actor: "claude_export.acquisition")
        graph.add_object("acquired_content", {
          "acquired_item_id"    => JSON::Any.new(acquired.id),
          "normalized_content"  => JSON::Any.new(record["normalized_content"].as_s),
          "normalized_metadata" => record["normalized_metadata"],
          "source_category"     => JSON::Any.new("ai_activity"),
          "connection_path"     => JSON::Any.new("export"),
          "is_fixture"          => JSON::Any.new(is_fixture),
        }.to_json, actor: "claude_export.acquisition")
        acquired_item_ids << acquired.id
        sender = record["sender"].as_s
        if sender == "human"
          human_count += 1
        elsif sender == "assistant"
          assistant_count += 1
        end
        cursor = _advance_cursor(graph, cursor, source_surface_id, record["provider_item_id"].as_s)
      end
    end

    {
      "ok"                 => JSON::Any.new(failure_ids.empty?),
      "imported"           => JSON::Any.new(acquired_item_ids.size),
      "failed"             => JSON::Any.new(failure_ids.size),
      "conversations"      => JSON::Any.new(conversation_count),
      "human_messages"     => JSON::Any.new(human_count),
      "assistant_messages" => JSON::Any.new(assistant_count),
      "cursor_id"          => cursor ? JSON::Any.new(cursor.id) : JSON::Any.new(nil),
      "acquired_item_ids"  => JSON::Any.new(acquired_item_ids.map { |item| JSON::Any.new(item) }),
      "failure_ids"        => JSON::Any.new(failure_ids.map { |failure| JSON::Any.new(failure) }),
      "stopped_at_bound"   => JSON::Any.new(stopped_at_bound),
    }
  end

  # Registered capability wrapper for import_claude_export_fn.
  @[Chronicle::Packs::Annotations::Tool(name: "import_claude_export", description: "Acquire a bounded official Claude data export (ZIP archive or bare conversations.json). Emits one Activity Normalizer acquired-item/content handoff per chat message; identity and dedup stay normalizer-owned.")]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream import_claude_export wrapper
  def import_claude_export_tool(args : String) : String
    input = JSON.parse(args).as_h
    graph = bound_graph_or_raise
    result = import_claude_export_fn(
      graph,
      input["export_path"]?.try(&.as_s?) || "",
      input["source_surface_id"]?.try(&.as_s?) || "",
      artifact_store_dir: input["artifact_store_dir"]?.try(&.as_s?) || ".activegraph/replay-artifacts",
      replay_mode: input["replay_mode"]?.try(&.as_s?) || "artifact",
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
      max_archive_bytes: (input["max_archive_bytes"]?.try(&.as_i64?) || 1_000_000_000_i64),
      max_conversations_json_bytes: (input["max_conversations_json_bytes"]?.try(&.as_i64?) || 256_000_000_i64),
      max_compression_ratio: input["max_compression_ratio"]?.try(&.as_i?) || 200,
      max_conversations: input["max_conversations"]?.try(&.as_i?) || 10_000,
      max_messages_per_conversation: input["max_messages_per_conversation"]?.try(&.as_i?) || 10_000,
      max_messages: input["max_messages"]?.try(&.as_i?) || 250_000,
      max_normalized_chars: input["max_normalized_chars"]?.try(&.as_i?) || 32_000,
    )
    result.to_json
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "claude_export tools require a bound graph (set ClaudeExport.bound_graph)"
    )
  end
end

require "json"
require "digest"
require "file_utils"
require "compress/zip"
require "time"

module Chronicle::Packs::ChatGPTExport
  # Bounded parser for official ChatGPT export ZIP snapshots. Ported from
  # upstream packs/importers/chatgpt_export/tools.py.
  #
  # conversations.json is a tree, not a transcript. The path ending at the
  # provider's current_node is emitted as canonical conversation evidence;
  # every other message node is also emitted and explicitly marked as an
  # abandoned edit/regeneration branch (a useful correction signal).
  module ImportConstants
    IMPORTER_ID             = "chatgpt_export"
    IMPORTER_VERSION        = "0.1.0"
    CONVERSATIONS_MEMBER    = "conversations.json"
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
  # sort_keys=True, separators=(",", ":")). Crystal's JSON::Serializable
  # doesn't sort keys, so build a canonical string by parsing and re-emitting
  # with sorted keys.
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
    }.to_json, actor: "chatgpt_export.acquisition")
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

  # Extract the text of one content part.
  def self._part_text(part : JSON::Any?) : String
    return "" if part.nil?
    case raw = part.raw
    when String
      raw
    when Int32, Int64, Float32, Float64, Bool
      raw.to_s
    when Nil
      ""
    when Hash(String, JSON::Any)
      ["text", "content", "result"].each do |key|
        if v = raw[key]?
          if v.raw.is_a?(String)
            return v.as_s
          end
        end
      end
      if nested = raw["parts"]?
        if nested.raw.is_a?(Array)
          return nested.as_a.compact_map { |item| _part_text(item) }.reject(&.empty?).join("\n")
        end
      end
      kind = raw["content_type"]?.try(&.as_s?) || raw["type"]?.try(&.as_s?) || "non_text"
      "[#{kind} content omitted]"
    else
      ""
    end
  end

  # Normalize one message's content to bounded text + metadata.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _normalized_message
  def self._normalized_message(message : JSON::Any, max_chars : Int32) : {String, Hash(String, JSON::Any)}
    m = message.as_h
    content = m["content"]?
    content_type = nil
    parts = [] of JSON::Any
    if content && content.raw.is_a?(Hash(String, JSON::Any))
      ch = content.as_h
      content_type = ch["content_type"]?.try(&.as_s?) || ch["type"]?.try(&.as_s?)
      if parts_val = ch["parts"]?
        if parts_val.raw.is_a?(Array)
          parts = parts_val.as_a
        end
      end
      if parts.empty?
        if text_val = ch["text"]?
          if text_val.raw.is_a?(String)
            parts = [text_val]
          end
        end
      end
      if parts.empty?
        parts = [content]
      end
    elsif content && content.raw.is_a?(String)
      parts = [content]
    elsif content && !content.raw.nil?
      parts = [content]
    end

    text = parts.compact_map { |part| _part_text(part) }.reject(&.empty?).join("\n")
    text = text.gsub("\r\n", "\n").gsub("\r", "\n")
    original_chars = text.size
    truncated = original_chars > max_chars
    if truncated
      text = text[0, max_chars]
    end
    meta = {} of String => JSON::Any
    meta["content_type"] = content_type ? JSON::Any.new(content_type) : JSON::Any.new(nil)
    meta["part_count"] = JSON::Any.new(parts.size)
    meta["normalized_char_count"] = JSON::Any.new(original_chars)
    meta["truncated"] = JSON::Any.new(truncated)
    {text, meta}
  end

  def self._author(message : JSON::Any) : {String?, String?}
    m = message.as_h
    author = m["author"]?
    if author.nil? || !author.raw.is_a?(Hash(String, JSON::Any))
      return {nil, nil}
    end
    ah = author.as_h
    role = ah["role"]?.try(&.as_s?)
    name = ah["name"]?.try(&.as_s?)
    {role, name}
  end

  # Validate node identity and parent chains before emitting a conversation.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _validate_mapping
  def self._validate_mapping(mapping : Hash(String, JSON::Any)) : Nil
    mapping.each do |node_id, node|
      if node_id.empty?
        raise ExportFormatError.new("mapping keys must be non-empty strings")
      end
      if !node.raw.is_a?(Hash(String, JSON::Any))
        raise ExportFormatError.new("node #{node_id.inspect} is not an object")
      end
      nd = node.as_h
      declared_id = nd["id"]?.try(&.as_s?)
      if declared_id && declared_id != node_id
        raise ExportFormatError.new("node id mismatch for mapping key #{node_id.inspect}")
      end
      parent = nd["parent"]?
      if parent && !parent.raw.nil? && !parent.raw.is_a?(String)
        raise ExportFormatError.new("node #{node_id.inspect} has a non-string parent")
      end
      children = nd["children"]?
      if children && (!children.raw.is_a?(Array) || children.as_a.any? { |child| !child.raw.is_a?(String) })
        raise ExportFormatError.new("node #{node_id.inspect} has invalid children")
      end

      visited = Set(String).new
      current = node_id
      loop do
        break if current.nil?
        if visited.includes?(current)
          raise ExportFormatError.new("cycle detected at node #{current.inspect}")
        end
        visited << current
        current_node = mapping[current]?
        if current_node.nil?
          raise ExportFormatError.new("node #{node_id.inspect} references missing parent #{current.inspect}")
        end
        current = current_node["parent"]?.try(&.as_s?)
      end
    end
  end

  # Return root-to-current path, selected leaf, and selection provenance.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _canonical_path
  def self._canonical_path(mapping : Hash(String, JSON::Any), current_node : JSON::Any?) : {Array(String), String, String}
    selection = "provider_current_node"
    leaf = current_node
    if leaf.nil? || leaf.raw.nil?
      leaves = [] of {String, String}
      mapping.each do |node_id, node|
        next unless node.raw.is_a?(Hash(String, JSON::Any))
        nd = node.as_h
        children = (nd["children"]?.try(&.as_a) || [] of JSON::Any).select { |child| mapping.has_key?(child.as_s) }
        message = nd["message"]?
        if children.empty? && message && message.raw.is_a?(Hash(String, JSON::Any))
          leaves << {(message.as_h["create_time"]?.try(&.as_s?) || ""), node_id}
        end
      end
      if leaves.empty?
        raise ExportFormatError.new("conversation has no current_node or message leaf")
      end
      leaf = JSON::Any.new(leaves.max[1])
      selection = "deterministic_latest_leaf_fallback"
    end
    if !leaf.raw.is_a?(String) || !mapping.has_key?(leaf.as_s)
      raise ExportFormatError.new("current_node does not identify a mapping node")
    end

    path = [] of String
    cursor = leaf.as_s
    while !cursor.nil?
      path << cursor
      nd = mapping[cursor].as_h
      cursor = nd["parent"]?.try(&.as_s?)
    end
    path.reverse!
    {path, leaf.as_s, selection}
  end

  def self._nearest_canonical_ancestor(node_id : String, mapping : Hash(String, JSON::Any), canonical : Set(String)) : String?
    parent = mapping[node_id].as_h["parent"]?.try(&.as_s?)
    while parent
      if canonical.includes?(parent)
        return parent
      end
      parent = mapping[parent].as_h["parent"]?.try(&.as_s?)
    end
    nil
  end

  # Parse one conversation into acquired-message records.
  # ameba:disable Metrics/CyclomaticComplexity,Lint/NotNil -- faithful port of upstream _conversation_records
  def self._conversation_records(conversation : JSON::Any, *, max_nodes : Int32, max_normalized_chars : Int32) : Array(Hash(String, JSON::Any))
    if !conversation.raw.is_a?(Hash(String, JSON::Any))
      raise ExportFormatError.new("conversation entry is not an object")
    end
    conv = conversation.as_h
    conversation_id = conv["id"]?.try(&.as_s?) || conv["conversation_id"]?.try(&.as_s?) || ""
    if conversation_id.empty?
      raise ExportFormatError.new("conversation has no stable id")
    end
    mapping = conv["mapping"]?
    if mapping.nil? || !mapping.raw.is_a?(Hash(String, JSON::Any)) || mapping.as_h.empty?
      raise ExportFormatError.new("conversation #{conversation_id.inspect} has no mapping")
    end
    mapping_h = mapping.as_h
    if mapping_h.size > max_nodes
      raise ExportFormatError.new("conversation #{conversation_id.inspect} has #{mapping_h.size} nodes; limit is #{max_nodes}")
    end
    _validate_mapping(mapping_h)
    canonical_path, canonical_leaf, selection = _canonical_path(mapping_h, conv["current_node"]?)
    canonical_set = canonical_path.to_set
    canonical_position = {} of String => Int32
    canonical_path.each_with_index { |node_id, index| canonical_position[node_id] = index }

    message_ids = mapping_h.select { |_node_id, node| node["message"]?.try(&.raw.is_a?(Hash(String, JSON::Any))) == true }.map(&.[0])
    ordered_ids = canonical_path.select { |node_id| message_ids.includes?(node_id) }
    ordered_ids.concat(message_ids.reject { |node_id| canonical_set.includes?(node_id) }.sort!)

    title = conv["title"]?.try(&.as_s?)
    records = [] of Hash(String, JSON::Any)
    ordered_ids.each do |node_id|
      node = mapping_h[node_id]
      msg = node["message"]?
      next if msg.nil?
      message = msg
      text, content_meta = _normalized_message(message, max_normalized_chars)
      role, author_name = _author(message)
      branch_status = canonical_set.includes?(node_id) ? "canonical" : "abandoned"
      children = (node["children"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
      parent_id = node["parent"]?.try(&.as_s?)
      sibling_index = nil
      if parent_id && mapping_h.has_key?(parent_id)
        siblings = (mapping_h[parent_id]["children"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
        sibling_index = siblings.index(node_id)
      end
      provider_time = _provider_time(
        message["create_time"]? || message["update_time"]? || conv["update_time"]? || conv["create_time"]?
      )

      normalized_metadata = {} of String => JSON::Any
      normalized_metadata["conversation_id"] = JSON::Any.new(conversation_id)
      normalized_metadata["conversation_title"] = title ? JSON::Any.new(title) : JSON::Any.new(nil)
      normalized_metadata["node_id"] = JSON::Any.new(node_id)
      normalized_metadata["message_id"] = JSON::Any.new(message["id"]?.try(&.as_s?) || node_id)
      normalized_metadata["parent_id"] = parent_id ? JSON::Any.new(parent_id) : JSON::Any.new(nil)
      normalized_metadata["children_ids"] = JSON::Any.new(children.map { |child| JSON::Any.new(child) })
      normalized_metadata["sibling_index"] = sibling_index ? JSON::Any.new(sibling_index) : JSON::Any.new(nil)
      normalized_metadata["role"] = role ? JSON::Any.new(role) : JSON::Any.new(nil)
      normalized_metadata["author_name"] = author_name ? JSON::Any.new(author_name) : JSON::Any.new(nil)
      normalized_metadata["message_status"] = message["status"]? || JSON::Any.new(nil)
      normalized_metadata["recipient"] = message["recipient"]? || JSON::Any.new(nil)
      normalized_metadata["branch_status"] = JSON::Any.new(branch_status)
      normalized_metadata["is_canonical"] = JSON::Any.new(branch_status == "canonical")
      normalized_metadata["correction_signal"] = JSON::Any.new(branch_status == "abandoned")
      normalized_metadata["canonical_path_index"] = canonical_position[node_id]? ? JSON::Any.new(canonical_position[node_id]) : JSON::Any.new(nil)
      normalized_metadata["canonical_leaf_id"] = JSON::Any.new(canonical_leaf)
      normalized_metadata["canonical_selection"] = JSON::Any.new(selection)
      normalized_metadata["nearest_canonical_ancestor_id"] = if branch_status == "canonical"
                                                               JSON::Any.new(nil)
                                                             else
                                                               anc = _nearest_canonical_ancestor(node_id, mapping_h, canonical_set)
                                                               anc ? JSON::Any.new(anc) : JSON::Any.new(nil)
                                                             end
      normalized_metadata["provider_time"] = provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
      content_meta.each { |k, v| normalized_metadata[k] = v }

      replay_unit = {} of String => JSON::Any
      replay_unit["conversation_id"] = JSON::Any.new(conversation_id)
      replay_unit["conversation_title"] = title ? JSON::Any.new(title) : JSON::Any.new(nil)
      replay_unit["node_id"] = JSON::Any.new(node_id)
      replay_unit["parent_id"] = parent_id ? JSON::Any.new(parent_id) : JSON::Any.new(nil)
      replay_unit["children_ids"] = JSON::Any.new(children.map { |child| JSON::Any.new(child) })
      replay_unit["message_id"] = JSON::Any.new(message["id"]?.try(&.as_s?) || node_id)
      replay_unit["role"] = role ? JSON::Any.new(role) : JSON::Any.new(nil)
      replay_unit["author_name"] = author_name ? JSON::Any.new(author_name) : JSON::Any.new(nil)
      replay_unit["provider_time"] = provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
      replay_unit["branch_status"] = JSON::Any.new(branch_status)
      replay_unit["normalized_content"] = JSON::Any.new(text)
      replay_unit["normalized_metadata"] = JSON::Any.new(normalized_metadata)

      records << {
        "conversation_id"     => JSON::Any.new(conversation_id),
        "node_id"             => JSON::Any.new(node_id),
        "dedup_key"           => JSON::Any.new("#{conversation_id}:#{node_id}"),
        "provider_item_id"    => JSON::Any.new("#{conversation_id}:#{node_id}"),
        "provider_time"       => provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil),
        "source_hash"         => JSON::Any.new(_sha256(_canonical_json(node).to_slice)),
        "normalized_content"  => JSON::Any.new(text),
        "normalized_metadata" => JSON::Any.new(normalized_metadata),
        "replay_payload"      => JSON::Any.new(_canonical_json(JSON::Any.new(replay_unit))),
        "branch_status"       => JSON::Any.new(branch_status),
      }
    end
    records
  end

  # Read and validate the archive's conversations.json.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _read_conversations
  def self._read_conversations(archive_path : String, *, max_archive_bytes : Int64, max_json_bytes : Int64, max_compression_ratio : Int32) : {Path, Array(JSON::Any)}
    archive = Path.new(archive_path).expand(home: true)
    if File.symlink?(archive) || !File.file?(archive)
      raise ExportFormatError.new("archive_path must be an existing, non-symlink ZIP file")
    end
    size = File.size(archive)
    if size > max_archive_bytes
      raise ExportFormatError.new("archive is #{size} bytes; limit is #{max_archive_bytes}")
    end
    archive = archive.expand
    raw = nil
    begin
      Compress::Zip::File.open(archive) do |zip|
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
    if raw.nil?
      raise ExportFormatError.new("archive has no root conversations.json")
    end
    parsed = begin
      JSON.parse(raw.to_s)
    rescue ex : JSON::ParseException
      raise ExportFormatError.new("malformed conversations.json: #{ex.message}")
    end
    if !parsed.raw.is_a?(Array)
      raise ExportFormatError.new("conversations.json root must be a list")
    end
    {archive, parsed.as_a}
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
      }.to_json, actor: "chatgpt_export.acquisition")
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
    graph.patch_object(cursor.id, current.to_json, actor: "chatgpt_export.acquisition")
    graph.get_object(cursor.id) || raise PackError.new("cursor #{cursor.id} vanished")
  end

  # URL-encode a path segment (upstream urllib.parse.quote).
  def self._quote(value : String) : String
    value.gsub(/[^A-Za-z0-9_\-.]/) do |char|
      "%" + char.bytes.map(&.to_s(16).upcase.rjust(2, '0')).join
    end
  end

  # Acquire one bounded official ChatGPT export snapshot.
  #
  # A malformed conversation is validated before any of its message objects
  # are emitted. Valid sibling conversations remain committed. Re-import and
  # snapshot overlap intentionally re-emit acquired records; the normalizer
  # owns evidence identity and deduplication.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream import_chatgpt_export_fn
  def self.import_chatgpt_export_fn(
    graph : Chronicle::GraphProjection,
    archive_path : String,
    source_surface_id : String,
    *,
    artifact_store_dir : String = ".activegraph/replay-artifacts",
    replay_mode : String = "artifact",
    is_fixture : Bool = false,
    max_archive_bytes : Int64 = 1_000_000_000,
    max_conversations_json_bytes : Int64 = 256_000_000,
    max_compression_ratio : Int32 = 200,
    max_conversations : Int32 = 10_000,
    max_nodes_per_conversation : Int32 = 100_000,
    max_messages : Int32 = 250_000,
    max_normalized_chars : Int32 = 32_000,
  ) : Hash(String, JSON::Any)
    unless ImportConstants::REPLAY_MODES.includes?(replay_mode)
      raise PackError.new("unsupported replay_mode #{replay_mode.inspect}")
    end
    if source_surface_id.empty?
      raise PackError.new("source_surface_id is required")
    end
    bounds = [max_archive_bytes, max_conversations_json_bytes, max_compression_ratio.to_i64, max_conversations.to_i64, max_nodes_per_conversation.to_i64, max_messages.to_i64, max_normalized_chars.to_i64]
    if bounds.any? { |v| v < 1 }
      raise PackError.new("all import bounds must be positive")
    end

    acquired_item_ids = [] of String
    failure_ids = [] of String
    canonical_count = 0
    abandoned_count = 0
    conversation_count = 0
    stopped_at_bound = false
    cursor = _find_cursor(graph, source_surface_id)

    begin
      archive, conversations = _read_conversations(
        archive_path,
        max_archive_bytes: max_archive_bytes,
        max_json_bytes: max_conversations_json_bytes,
        max_compression_ratio: max_compression_ratio,
      )
    rescue ex : ExportFormatError | IO::Error
      failure_ids << _record_failure(
        graph,
        source_surface_id: source_surface_id,
        source_ref: Path.new(archive_path).expand(home: true).to_s,
        error_code: "invalid_export",
        message: ex.message.to_s,
        recoverable: ex.is_a?(IO::Error),
      )
      return {
        "ok"                 => JSON::Any.new(false),
        "imported"           => JSON::Any.new(0),
        "failed"             => JSON::Any.new(1),
        "conversations"      => JSON::Any.new(0),
        "canonical_messages" => JSON::Any.new(0),
        "abandoned_messages" => JSON::Any.new(0),
        "cursor_id"          => cursor ? JSON::Any.new(cursor.id) : JSON::Any.new(nil),
        "acquired_item_ids"  => JSON::Any.new([] of JSON::Any),
        "failure_ids"        => JSON::Any.new([] of JSON::Any),
        "stopped_at_bound"   => JSON::Any.new(false),
      }
    end

    if conversations.size > max_conversations
      stopped_at_bound = true
      failure_ids << _record_failure(
        graph,
        source_surface_id: source_surface_id,
        source_ref: "#{archive}!/#{ImportConstants::CONVERSATIONS_MEMBER}",
        error_code: "conversation_bound_reached",
        message: "export has #{conversations.size} conversations; limit is #{max_conversations}",
        recoverable: true,
        metadata: {"available" => JSON::Any.new(conversations.size), "limit" => JSON::Any.new(max_conversations)},
      )
    end
    conversations.first(max_conversations).each_with_index do |conversation, index|
      raw_id = conversation.raw.is_a?(Hash(String, JSON::Any)) ? conversation.as_h["id"]?.try(&.as_s?) : nil
      conversation_ref = "#{archive}!/#{ImportConstants::CONVERSATIONS_MEMBER}#conversation=#{_quote(raw_id || index.to_s)}"
      begin
        records = _conversation_records(
          conversation,
          max_nodes: max_nodes_per_conversation,
          max_normalized_chars: max_normalized_chars,
        )
      rescue ex : ExportFormatError
        failure_ids << _record_failure(
          graph,
          source_surface_id: source_surface_id,
          source_ref: conversation_ref,
          error_code: "invalid_conversation",
          message: ex.message.to_s,
          metadata: {"conversation_index" => JSON::Any.new(index), "conversation_id" => raw_id ? JSON::Any.new(raw_id) : JSON::Any.new(nil)},
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
        source_ref = "#{archive}!/#{ImportConstants::CONVERSATIONS_MEMBER}#conversation=#{_quote(record["conversation_id"].as_s)}&node=#{_quote(record["node_id"].as_s)}"
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
        }.to_json, actor: "chatgpt_export.acquisition")
        graph.add_object("acquired_content", {
          "acquired_item_id"    => JSON::Any.new(acquired.id),
          "normalized_content"  => JSON::Any.new(record["normalized_content"].as_s),
          "normalized_metadata" => record["normalized_metadata"],
          "source_category"     => JSON::Any.new("ai_activity"),
          "connection_path"     => JSON::Any.new("export"),
          "is_fixture"          => JSON::Any.new(is_fixture),
        }.to_json, actor: "chatgpt_export.acquisition")
        acquired_item_ids << acquired.id
        if record["branch_status"].as_s == "canonical"
          canonical_count += 1
        else
          abandoned_count += 1
        end
        cursor = _advance_cursor(graph, cursor, source_surface_id, record["provider_item_id"].as_s)
      end
    end

    {
      "ok"                 => JSON::Any.new(failure_ids.empty?),
      "imported"           => JSON::Any.new(acquired_item_ids.size),
      "failed"             => JSON::Any.new(failure_ids.size),
      "conversations"      => JSON::Any.new(conversation_count),
      "canonical_messages" => JSON::Any.new(canonical_count),
      "abandoned_messages" => JSON::Any.new(abandoned_count),
      "cursor_id"          => cursor ? JSON::Any.new(cursor.id) : JSON::Any.new(nil),
      "acquired_item_ids"  => JSON::Any.new(acquired_item_ids.map { |item| JSON::Any.new(item) }),
      "failure_ids"        => JSON::Any.new(failure_ids.map { |failure| JSON::Any.new(failure) }),
      "stopped_at_bound"   => JSON::Any.new(stopped_at_bound),
    }
  end

  # Registered capability wrapper for import_chatgpt_export_fn.
  @[Chronicle::Packs::Annotations::Tool(name: "import_chatgpt_export", description: "Acquire a bounded official ChatGPT export ZIP. Preserves the current conversation path and abandoned edit/regeneration branches as distinct Activity Normalizer handoffs.")]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream import_chatgpt_export wrapper
  def import_chatgpt_export_tool(args : String) : String
    input = JSON.parse(args).as_h
    graph = bound_graph_or_raise
    result = import_chatgpt_export_fn(
      graph,
      input["archive_path"]?.try(&.as_s?) || "",
      input["source_surface_id"]?.try(&.as_s?) || "",
      artifact_store_dir: input["artifact_store_dir"]?.try(&.as_s?) || ".activegraph/replay-artifacts",
      replay_mode: input["replay_mode"]?.try(&.as_s?) || "artifact",
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
      max_archive_bytes: (input["max_archive_bytes"]?.try(&.as_i64?) || 1_000_000_000_i64),
      max_conversations_json_bytes: (input["max_conversations_json_bytes"]?.try(&.as_i64?) || 256_000_000_i64),
      max_compression_ratio: input["max_compression_ratio"]?.try(&.as_i?) || 200,
      max_conversations: input["max_conversations"]?.try(&.as_i?) || 10_000,
      max_nodes_per_conversation: input["max_nodes_per_conversation"]?.try(&.as_i?) || 100_000,
      max_messages: input["max_messages"]?.try(&.as_i?) || 250_000,
      max_normalized_chars: input["max_normalized_chars"]?.try(&.as_i?) || 32_000,
    )
    result.to_json
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "chatgpt_export tools require a bound graph (set ChatGPTExport.bound_graph)"
    )
  end
end

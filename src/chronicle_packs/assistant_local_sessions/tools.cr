require "json"
require "digest"
require "file_utils"
require "time"

module Chronicle::Packs::AssistantLocalSessions
  # Bounded importer for local agent-session JSONL logs (Claude Code, Codex).
  # Ported from upstream packs/importers/assistant_local_sessions/tools.py.
  #
  # Both layouts are unversioned, append-only JSONL written by tools that
  # change shape between releases. The parsers here are therefore
  # deliberately defensive: a line either yields exactly one user/assistant
  # message unit or it is skipped and counted; a file either parses within
  # bounds or it records one `ingestion_failure` and its siblings continue.
  # Content problems never raise out of the tool.
  module ImportConstants
    IMPORTER_ID             = "assistant_local_sessions"
    IMPORTER_VERSION        = "0.1.0"
    PROVIDERS               = Set{"claude_code", "codex"}
    REPLAY_MODES            = Set{"inline", "artifact", "reference_only"}
    REFERENCE_ONLY_SENTINEL = "reference_only:no-payload"
    MESSAGE_ROLES           = Set{"user", "assistant"}
    CLAUDE_TEXT_PART_TYPES  = Set{"text"}
    CODEX_TEXT_PART_TYPES   = Set{"input_text", "output_text", "text"}
    CODEX_FILENAME_RE       = /^rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-(.+)\.jsonl$/
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
    }.to_json, actor: "assistant_local_sessions.acquisition")
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

  # Return the line's own timestamp string only when it parses as ISO-8601.
  def self._provider_time(value : JSON::Any?) : String?
    return nil if value.nil?
    s = value.raw.is_a?(String) ? value.as_s : (value.try(&.to_s) || "")
    return nil if s.strip.empty?
    candidate = s.strip
    if candidate.ends_with?("Z") || candidate.ends_with?("z")
      candidate = candidate[0..-2] + "+00:00"
    end
    begin
      Time.parse_iso8601(candidate)
    rescue
      return nil
    end
    s.strip
  end

  # Join plain-string and typed text parts; every other part shape is skipped.
  def self._joined_text(content : JSON::Any?, text_part_types : Set(String)) : {String, Int32}
    raw_parts = [] of JSON::Any
    if content && content.raw.is_a?(String)
      raw_parts = [content]
    elsif content && content.raw.is_a?(Array)
      raw_parts = content.as_a
    end
    texts = [] of String
    raw_parts.each do |part|
      if part.raw.is_a?(String)
        texts << part.as_s
      elsif part.raw.is_a?(Hash(String, JSON::Any))
        ph = part.as_h
        part_type = ph["type"]?.try(&.as_s?)
        if text_val = ph["text"]?
          if (part_type.nil? || text_part_types.includes?(part_type)) && text_val.raw.is_a?(String)
            texts << text_val.as_s
          end
        end
      end
    end
    text = texts.reject(&.empty?).join("\n")
    text = text.gsub("\r\n", "\n").gsub("\r", "\n")
    {text, raw_parts.size}
  end

  # One Claude Code JSONL line -> message unit, or (nil, skip_reason).
  #
  # Non-message line types (summary, system, attachment, titles, queue
  # operations, hooks, ...) and user/assistant lines carrying only
  # tool_use/tool_result/thinking parts are skipped, never failed.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _extract_claude_code
  def self._extract_claude_code(obj : Hash(String, JSON::Any)) : {Hash(String, JSON::Any)?, String}
    obj_type = obj["type"]?.try(&.as_s?) || ""
    unless ImportConstants::MESSAGE_ROLES.includes?(obj_type)
      return {nil, "non_message"}
    end
    message = obj["message"]?
    if message.nil? || !message.raw.is_a?(Hash(String, JSON::Any))
      return {nil, "non_message"}
    end
    m = message.as_h
    role = m["role"]?.try(&.as_s?)
    if role.nil? || role.empty?
      role = obj_type
    end
    unless ImportConstants::MESSAGE_ROLES.includes?(role)
      return {nil, "non_message"}
    end
    text, part_count = _joined_text(m["content"]?, ImportConstants::CLAUDE_TEXT_PART_TYPES)
    if text.strip.empty?
      return {nil, "non_text"}
    end
    uuid = obj["uuid"]?.try(&.as_s?)
    session_id = obj["sessionId"]?.try(&.as_s?)
    cwd = obj["cwd"]?.try(&.as_s?)
    unit = {} of String => JSON::Any
    unit["role"] = JSON::Any.new(role)
    unit["text"] = JSON::Any.new(text)
    unit["part_count"] = JSON::Any.new(part_count)
    unit["message_uuid"] = uuid && !uuid.empty? ? JSON::Any.new(uuid) : JSON::Any.new(nil)
    unit["timestamp"] = obj["timestamp"]? || JSON::Any.new(nil)
    unit["line_session_id"] = session_id && !session_id.empty? ? JSON::Any.new(session_id) : JSON::Any.new(nil)
    unit["cwd"] = cwd && !cwd.empty? ? JSON::Any.new(cwd) : JSON::Any.new(nil)
    {unit, ""}
  end

  # One Codex rollout JSONL line -> message unit, or (nil, skip_reason).
  #
  # Accepts the nested response_item/payload.message shape and the older
  # flat `{"type": "message", ...}` variant. session_meta, event_msg,
  # turn_context, tool call records, and non-user/assistant roles are
  # skipped, never failed.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream _extract_codex
  def self._extract_codex(obj : Hash(String, JSON::Any)) : {Hash(String, JSON::Any)?, String}
    record_type = obj["type"]?.try(&.as_s?)
    payload = nil
    if record_type == "response_item"
      candidate = obj["payload"]?
      if candidate && candidate.raw.is_a?(Hash(String, JSON::Any)) && candidate.as_h["type"]?.try(&.as_s?) == "message"
        payload = candidate.as_h
      end
    elsif record_type == "message"
      payload = obj
    end
    if payload.nil?
      return {nil, "non_message"}
    end
    role = payload["role"]?.try(&.as_s?) || ""
    unless ImportConstants::MESSAGE_ROLES.includes?(role)
      return {nil, "non_message"}
    end
    text, part_count = _joined_text(payload["content"]?, ImportConstants::CODEX_TEXT_PART_TYPES)
    if text.strip.empty?
      return {nil, "non_text"}
    end
    uuid = payload["id"]?.try(&.as_s?)
    unit = {} of String => JSON::Any
    unit["role"] = JSON::Any.new(role)
    unit["text"] = JSON::Any.new(text)
    unit["part_count"] = JSON::Any.new(part_count)
    unit["message_uuid"] = uuid && !uuid.empty? ? JSON::Any.new(uuid) : JSON::Any.new(nil)
    ts = obj["timestamp"]? || payload["timestamp"]?
    unit["timestamp"] = ts ? ts : JSON::Any.new(nil)
    unit["line_session_id"] = JSON::Any.new(nil)
    unit["cwd"] = JSON::Any.new(nil)
    {unit, ""}
  end

  # Resolve (session_id, session_cwd) from the first session_meta record.
  #
  # Falls back to the rollout filename UUID, then the filename stem. Only the
  # first well-formed session_meta wins so forked/resumed rollouts keep one
  # stable identity.
  def self._codex_session_identity(path : Path, lines : Array(String)) : {String, String?}
    lines.each do |raw|
      stripped = raw.strip
      next if stripped.empty?
      obj = begin
        JSON.parse(stripped).as_h
      rescue
        next
      end
      next unless obj["type"]?.try(&.as_s?) == "session_meta"
      payload = obj["payload"]?
      next unless payload && payload.raw.is_a?(Hash(String, JSON::Any))
      ph = payload.as_h
      meta_id = ph["id"]?.try(&.as_s?) || ph["session_id"]?.try(&.as_s?)
      cwd = ph["cwd"]?.try(&.as_s?)
      if meta_id && !meta_id.empty?
        return {meta_id, cwd && !cwd.empty? ? cwd : nil}
      end
    end
    if m = path.basename.match(ImportConstants::CODEX_FILENAME_RE)
      return {m[2], nil}
    end
    {path.stem, nil}
  end

  # Collect regular non-symlink `.jsonl` files without following symlinks.
  def self._walk_jsonl_files(root : Path) : Array(Path)
    found = [] of Path
    Dir.glob("#{root}/**/*", follow_symlinks: false).sort.each do |entry|
      path = Path.new(entry)
      next if File.symlink?(path)
      next unless File.file?(path)
      next unless path.extension.downcase == ".jsonl"
      found << path
    end
    found
  end

  # Return (selected ascending-order entries, considered, skipped, order key).
  #
  # Claude Code files are ordered by file mtime with a relative-filename
  # tiebreak; Codex rollouts by the timestamp embedded in the filename. The
  # window keeps the most recent max_sessions files.
  def self._discover_windowed_files(root : Path, provider : String, max_sessions : Int32) : {Array(Hash(String, JSON::Any)), Int32, Int32, String}
    entries = [] of Hash(String, JSON::Any)
    order_key_name = "file_mtime_then_name"
    if provider == "codex"
      order_key_name = "filename_timestamp"
      _walk_jsonl_files(root).each do |path|
        m = path.basename.match(ImportConstants::CODEX_FILENAME_RE)
        next if m.nil?
        ref = path.relative_to(root).to_s
        entries << {
          "path"               => JSON::Any.new(path.to_s),
          "ref"                => JSON::Any.new(ref),
          "order_key"          => JSON::Any.new("#{m[1]}\x1f#{ref}"),
          "filename_timestamp" => JSON::Any.new(m[1]),
        }
      end
    else
      _walk_jsonl_files(root).each do |path|
        ref = path.relative_to(root).to_s
        mtime_ns = File.info(path).modification_time.to_unix_ms * 1_000_000
        entries << {
          "path"          => JSON::Any.new(path.to_s),
          "ref"           => JSON::Any.new(ref),
          "order_key"     => JSON::Any.new("#{mtime_ns}\x1f#{ref}"),
          "file_mtime_ns" => JSON::Any.new(mtime_ns),
        }
      end
    end
    entries.sort_by!(&.["order_key"].as_s).reverse!
    considered = entries.size
    selected = entries.first(max_sessions)
    skipped_by_window = considered - selected.size
    selected.reverse!
    {selected, considered, skipped_by_window, order_key_name}
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
      }.to_json, actor: "assistant_local_sessions.acquisition")
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
    graph.patch_object(cursor.id, current.to_json, actor: "assistant_local_sessions.acquisition")
    graph.get_object(cursor.id) || raise PackError.new("cursor #{cursor.id} vanished")
  end

  # Read a session file with size + UTF-8 validation (upstream's bounded read
  # + `payload.decode("utf-8")`; Crystal substitutes invalid bytes, so the
  # encoding is checked explicitly).
  def self._read_file_text(path : Path, max_file_bytes : Int64) : String
    size = File.size(path)
    if size > max_file_bytes
      raise PackError.new("file is #{size} bytes; limit is #{max_file_bytes}")
    end
    payload = File.open(path, "rb", &.gets_to_end.to_slice)
    if payload.size > max_file_bytes
      raise PackError.new("file grew to #{payload.size} bytes while reading; limit is #{max_file_bytes}")
    end
    decoded = String.new(payload)
    raise PackError.new("file is not valid UTF-8") unless decoded.valid_encoding?
    decoded
  end

  # Acquire a bounded window of local agent-session logs for one provider.
  #
  # One call imports one provider layout rooted at root_path. The window keeps
  # the max_sessions most recent session files under a deterministic order key
  # and is fully recorded in the returned window log. One
  # acquired_item/acquired_content pair is emitted per user/assistant message
  # line; a malformed line is skipped and counted; a malformed or unreadable
  # file records a recoverable ingestion_failure and its siblings continue.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream import_assistant_local_sessions_fn
  def self.import_assistant_local_sessions_fn(
    graph : Chronicle::GraphProjection,
    root_path : String,
    source_surface_id : String,
    *,
    provider : String = "claude_code",
    artifact_store_dir : String = ".activegraph/replay-artifacts",
    replay_mode : String = "artifact",
    is_fixture : Bool = false,
    max_sessions : Int32 = 20,
    max_file_bytes : Int64 = 50_000_000,
    max_lines_per_file : Int32 = 100_000,
    max_messages : Int32 = 25_000,
    max_normalized_chars : Int32 = 16_000,
  ) : Hash(String, JSON::Any)
    unless ImportConstants::PROVIDERS.includes?(provider)
      raise PackError.new("unsupported provider #{provider.inspect}")
    end
    unless ImportConstants::REPLAY_MODES.includes?(replay_mode)
      raise PackError.new("unsupported replay_mode #{replay_mode.inspect}")
    end
    if source_surface_id.empty?
      raise PackError.new("source_surface_id is required")
    end
    bounds = [max_sessions.to_i64, max_file_bytes, max_lines_per_file.to_i64, max_messages.to_i64, max_normalized_chars.to_i64]
    if bounds.any? { |v| v < 1 }
      raise PackError.new("all import bounds must be positive")
    end

    acquired_item_ids = [] of String
    failure_ids = [] of String
    malformed_lines = 0
    skipped_lines = 0
    files_imported = [] of String
    files_failed = [] of String
    stopped_at_bound = false
    cursor = _find_cursor(graph, source_surface_id)

    root = Path.new(root_path).expand(home: true)
    if File.symlink?(root) || !File.exists?(root) || !File.directory?(root)
      failure_ids << _record_failure(
        graph,
        source_surface_id: source_surface_id,
        source_ref: root.to_s,
        error_code: "invalid_root",
        message: "root_path must be an existing, non-symlink directory",
        recoverable: true,
      )
      return _result(failure_ids, acquired_item_ids, provider, files_imported, files_failed, malformed_lines, skipped_lines, stopped_at_bound, cursor, {} of String => JSON::Any, ok_hint: false)
    end
    root = root.expand

    selected, considered, skipped_by_window, order_key_name = _discover_windowed_files(root, provider, max_sessions)
    selected_refs = selected.map do |entry|
      row = {} of String => JSON::Any
      entry.each do |key, value|
        next if key == "path" || key == "order_key"
        row[key] = value
      end
      row
    end
    window_base = {
      "provider"                => JSON::Any.new(provider),
      "order_key"               => JSON::Any.new(order_key_name),
      "max_sessions"            => JSON::Any.new(max_sessions),
      "files_considered"        => JSON::Any.new(considered),
      "files_selected"          => JSON::Any.new(selected_refs.map { |row| JSON::Any.new(row) }),
      "files_skipped_by_window" => JSON::Any.new(skipped_by_window),
    }

    selected.each do |entry|
      path = Path.new(entry["path"].as_s)
      session_ref = entry["ref"].as_s
      file_source_ref = path.to_s
      text = begin
        _read_file_text(path, max_file_bytes)
      rescue ex : PackError | IO::Error
        files_failed << session_ref
        failure_ids << _record_failure(
          graph,
          source_surface_id: source_surface_id,
          source_ref: file_source_ref,
          error_code: "unreadable_file",
          message: ex.message.to_s,
          recoverable: true,
          metadata: {"session_ref" => JSON::Any.new(session_ref), "provider" => JSON::Any.new(provider)},
        )
        next
      end

      lines = text.split('\n')
      if lines.size > max_lines_per_file
        failure_ids << _record_failure(
          graph,
          source_surface_id: source_surface_id,
          source_ref: file_source_ref,
          error_code: "line_bound_reached",
          message: "file has #{lines.size} lines; only the first #{max_lines_per_file} were considered",
          recoverable: true,
          metadata: {"session_ref" => JSON::Any.new(session_ref), "line_count" => JSON::Any.new(lines.size), "limit" => JSON::Any.new(max_lines_per_file)},
        )
        lines = lines.first(max_lines_per_file)
      end

      if provider == "codex"
        file_session_id, session_cwd = _codex_session_identity(path, lines)
      else
        file_session_id = path.stem
        session_cwd = nil
      end

      imported_this_file = 0
      lines.each_with_index do |raw_line, line_index|
        line_number = line_index + 1
        stripped = raw_line.strip
        next if stripped.empty?
        if acquired_item_ids.size >= max_messages
          stopped_at_bound = true
          failure_ids << _record_failure(
            graph,
            source_surface_id: source_surface_id,
            source_ref: "#{file_source_ref}#L#{line_number}",
            error_code: "message_bound_reached",
            message: "run reached the message limit #{max_messages}",
            recoverable: true,
            metadata: {"session_ref" => JSON::Any.new(session_ref), "limit" => JSON::Any.new(max_messages)},
          )
          break
        end
        obj = begin
          JSON.parse(stripped).as_h
        rescue
          malformed_lines += 1
          next
        end
        unit, _skip = provider == "codex" ? _extract_codex(obj) : _extract_claude_code(obj)
        if unit.nil?
          skipped_lines += 1
          next
        end
        u = unit

        session_id = u["line_session_id"]?.try(&.as_s?) || file_session_id
        stable_suffix = if mu = u["message_uuid"]?.try(&.as_s?)
                          mu
                        else
                          "line-#{line_number}"
                        end
        provider_item_id = "#{session_id}:#{stable_suffix}"
        source_ref = "#{file_source_ref}#L#{line_number}"
        provider_time = _provider_time(u["timestamp"]?)

        content_text = u["text"].as_s
        original_chars = content_text.size
        truncated = original_chars > max_normalized_chars
        if truncated
          content_text = content_text[0, max_normalized_chars]
        end

        normalized_metadata = {} of String => JSON::Any
        normalized_metadata["provider"] = JSON::Any.new(provider)
        normalized_metadata["session_id"] = JSON::Any.new(session_id)
        normalized_metadata["session_ref"] = JSON::Any.new(session_ref)
        normalized_metadata["line_number"] = JSON::Any.new(line_number)
        normalized_metadata["message_uuid"] = u["message_uuid"]? || JSON::Any.new(nil)
        normalized_metadata["role"] = u["role"]? || JSON::Any.new(nil)
        normalized_metadata["provider_time"] = provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
        normalized_metadata["cwd"] = u["cwd"]?.try(&.as_s?) || session_cwd ? JSON::Any.new(u["cwd"]?.try(&.as_s?) || session_cwd) : JSON::Any.new(nil)
        normalized_metadata["part_count"] = u["part_count"]? || JSON::Any.new(nil)
        normalized_metadata["normalized_char_count"] = JSON::Any.new(original_chars)
        normalized_metadata["truncated"] = JSON::Any.new(truncated)
        if v = entry["file_mtime_ns"]?
          normalized_metadata["file_mtime_ns"] = v
        end
        if v = entry["filename_timestamp"]?
          normalized_metadata["filename_timestamp"] = v
        end

        replay_unit = {} of String => JSON::Any
        replay_unit["provider"] = JSON::Any.new(provider)
        replay_unit["session_id"] = JSON::Any.new(session_id)
        replay_unit["session_ref"] = JSON::Any.new(session_ref)
        replay_unit["line_number"] = JSON::Any.new(line_number)
        replay_unit["message_uuid"] = u["message_uuid"]? || JSON::Any.new(nil)
        replay_unit["role"] = u["role"]? || JSON::Any.new(nil)
        replay_unit["provider_time"] = provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil)
        replay_unit["normalized_content"] = JSON::Any.new(content_text)
        replay_unit["normalized_metadata"] = JSON::Any.new(normalized_metadata)

        replay_ref, replay_hash = begin
          _replay_reference(_canonical_json(JSON::Any.new(replay_unit)), replay_mode: replay_mode, artifact_store_dir: artifact_store_dir)
        rescue ex : IO::Error
          failure_ids << _record_failure(
            graph,
            source_surface_id: source_surface_id,
            source_ref: source_ref,
            error_code: "artifact_write_failed",
            message: ex.message.to_s,
            recoverable: true,
            metadata: {"provider_item_id" => JSON::Any.new(provider_item_id)},
          )
          next
        end

        acquired = graph.add_object("acquired_item", {
          "source_surface_id"   => JSON::Any.new(source_surface_id),
          "provider_item_id"    => JSON::Any.new(provider_item_id),
          "dedup_key"           => JSON::Any.new(provider_item_id),
          "source_ref"          => JSON::Any.new(source_ref),
          "source_hash"         => JSON::Any.new(_sha256(stripped)),
          "provider_time"       => provider_time ? JSON::Any.new(provider_time) : JSON::Any.new(nil),
          "replay_mode"         => JSON::Any.new(replay_mode),
          "replay_payload_ref"  => JSON::Any.new(replay_ref),
          "replay_payload_hash" => JSON::Any.new(replay_hash),
          "media_type"          => JSON::Any.new("application/json"),
          "importer_id"         => JSON::Any.new(ImportConstants::IMPORTER_ID),
          "importer_version"    => JSON::Any.new(ImportConstants::IMPORTER_VERSION),
        }.to_json, actor: "assistant_local_sessions.acquisition")
        graph.add_object("acquired_content", {
          "acquired_item_id"    => JSON::Any.new(acquired.id),
          "normalized_content"  => JSON::Any.new(content_text),
          "normalized_metadata" => JSON::Any.new(normalized_metadata),
          "source_category"     => JSON::Any.new("ai_activity"),
          "connection_path"     => JSON::Any.new("local"),
          "is_fixture"          => JSON::Any.new(is_fixture),
        }.to_json, actor: "assistant_local_sessions.acquisition")
        acquired_item_ids << acquired.id
        imported_this_file += 1
      end

      if imported_this_file > 0
        files_imported << session_ref
        cursor = _advance_cursor(graph, cursor, source_surface_id, session_ref)
      end
      break if stopped_at_bound
    end

    _result(failure_ids, acquired_item_ids, provider, files_imported, files_failed, malformed_lines, skipped_lines, stopped_at_bound, cursor, window_base)
  end

  private def self._result(failure_ids : Array(String), acquired_item_ids : Array(String), provider : String, files_imported : Array(String), files_failed : Array(String), malformed_lines : Int32, skipped_lines : Int32, stopped_at_bound : Bool, cursor : Chronicle::GraphObject?, window_base : Hash(String, JSON::Any), *, ok_hint : Bool = true) : Hash(String, JSON::Any)
    window = window_base.dup
    window["files_imported"] = JSON::Any.new(files_imported.map { |file| JSON::Any.new(file) })
    window["files_failed"] = JSON::Any.new(files_failed.map { |file| JSON::Any.new(file) })
    {
      "ok"                => JSON::Any.new(ok_hint && failure_ids.empty?),
      "provider"          => JSON::Any.new(provider),
      "imported"          => JSON::Any.new(acquired_item_ids.size),
      "failed"            => JSON::Any.new(failure_ids.size),
      "sessions_imported" => JSON::Any.new(files_imported.size),
      "malformed_lines"   => JSON::Any.new(malformed_lines),
      "skipped_lines"     => JSON::Any.new(skipped_lines),
      "window"            => JSON::Any.new(window),
      "cursor_id"         => cursor ? JSON::Any.new(cursor.id) : JSON::Any.new(nil),
      "acquired_item_ids" => JSON::Any.new(acquired_item_ids.map { |item| JSON::Any.new(item) }),
      "failure_ids"       => JSON::Any.new(failure_ids.map { |failure| JSON::Any.new(failure) }),
      "stopped_at_bound"  => JSON::Any.new(stopped_at_bound),
    }
  end

  # Registered capability wrapper for import_assistant_local_sessions_fn.
  @[Chronicle::Packs::Annotations::Tool(name: "import_assistant_local_sessions", description: "Acquire a bounded window of the most recent local agent-session JSONL logs (Claude Code projects/ or Codex sessions/). Emits Activity Normalizer acquired-item/content records per user/assistant message line; it does not deduplicate, extract candidates, or promote state.")]
  def import_assistant_local_sessions_tool(args : String) : String
    input = JSON.parse(args).as_h
    graph = bound_graph_or_raise
    result = import_assistant_local_sessions_fn(
      graph,
      input["root_path"]?.try(&.as_s?) || "",
      input["source_surface_id"]?.try(&.as_s?) || "",
      provider: input["provider"]?.try(&.as_s?) || "claude_code",
      artifact_store_dir: input["artifact_store_dir"]?.try(&.as_s?) || ".activegraph/replay-artifacts",
      replay_mode: input["replay_mode"]?.try(&.as_s?) || "artifact",
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
      max_sessions: input["max_sessions"]?.try(&.as_i?) || 20,
      max_file_bytes: (input["max_file_bytes"]?.try(&.as_i64?) || 50_000_000_i64),
      max_lines_per_file: input["max_lines_per_file"]?.try(&.as_i?) || 100_000,
      max_messages: input["max_messages"]?.try(&.as_i?) || 25_000,
      max_normalized_chars: input["max_normalized_chars"]?.try(&.as_i?) || 16_000,
    )
    result.to_json
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "assistant_local_sessions tools require a bound graph (set AssistantLocalSessions.bound_graph)"
    )
  end
end

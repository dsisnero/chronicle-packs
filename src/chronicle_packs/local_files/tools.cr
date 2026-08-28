require "json"
require "digest"
require "file_utils"

module Chronicle::Packs::LocalFiles
  # Bounded, deterministic local text/Markdown/JSON acquisition. Ported from
  # upstream packs/importers/local_files/tools.py.
  #
  # This module deliberately owns only the file-format edge. It never creates
  # evidence, computes evidence identity, deduplicates, or promotes
  # candidates. For every valid source file it records an `acquired_item`
  # followed by its provider-neutral `acquired_content` handoff. Activity
  # Normalizer reacts to those graph objects later.
  module ImportConstants
    IMPORTER_ID             = "local_files"
    IMPORTER_VERSION        = "0.1.0"
    DEFAULT_EXTENSIONS      = [".txt", ".md", ".markdown", ".json"] of String
    REPLAY_MODES            = Set{"inline", "artifact", "reference_only"}
    REFERENCE_ONLY_SENTINEL = "reference_only:no-payload"
  end

  def self._sha256(payload : Bytes) : String
    Digest::SHA256.hexdigest(payload)
  end

  # Append one bounded acquisition failure and return its graph id.
  def self._record_failure(
    graph : Chronicle::GraphProjection,
    *,
    source_surface_id : String?,
    source_ref : String?,
    error_code : String,
    message : String,
    provider_item_id : String? = nil,
    recoverable : Bool = false,
    metadata : Hash(String, JSON::Any)? = nil,
  ) : String
    details = (metadata || {} of String => JSON::Any).dup
    if provider_item_id
      details["provider_item_id"] = JSON::Any.new(provider_item_id)
    end
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
      "metadata"          => JSON::Any.new(details),
    }.to_json, actor: "local_files.acquisition")
    failure.id
  end

  # Persist exact replay bytes once and return (URI, digest).
  #
  # Layout is the shared v0 contract:
  #   <artifact_store>/sha256/<first-two-hex>/<full-hex>
  #
  # Existing content is verified before reuse. Writes use an atomic rename so
  # interruption leaves either the prior complete artifact or no artifact.
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

  def self._replay_reference(text : String, *, replay_mode : String, artifact_store_dir : String) : {String, String}
    payload = text.to_slice
    digest = _sha256(payload)
    if replay_mode == "inline"
      return {text, digest}
    end
    if replay_mode == "reference_only"
      return {ImportConstants::REFERENCE_ONLY_SENTINEL, digest}
    end
    ref, stored_digest = _artifact_ref(payload, artifact_store_dir)
    {ref, stored_digest}
  end

  def self._media_type(suffix : String) : String
    if suffix == ".json"
      "application/json"
    elsif suffix.in?({".md", ".markdown"})
      "text/markdown"
    else
      "text/plain"
    end
  end

  # The JSON root's structural kind, in the JSON spec's language-neutral
  # vocabulary (object/array/string/number/boolean/null). Upstream records
  # Python's `type(parsed).__name__` here; that value is informational
  # metadata only (nothing consumes it), so the port records the JSON type
  # instead of any language's runtime type names.
  def self._json_root_type(value : JSON::Any) : String
    case value.raw
    when Hash             then "object"
    when Array            then "array"
    when String           then "string"
    when Int32, Int64     then "number"
    when Float32, Float64 then "number"
    when Bool             then "boolean"
    when Nil              then "null"
    else                       value.raw.class.name
    end
  end

  # Return bounded reasoning content, validating JSON before any emit.
  def self._normalize_content(text : String, *, suffix : String, max_chars : Int32) : {String, Hash(String, JSON::Any)}
    normalized = text.gsub("\r\n", "\n").gsub("\r", "\n")
    json_metadata = {} of String => JSON::Any
    if suffix == ".json"
      parsed = JSON.parse(normalized)
      normalized = JSON.build do |json|
        json.raw(parsed.to_json) # compact: JSON.build with raw preserves order
      end
      # Compact (no whitespace) sorted-keys canonical form.
      if parsed.raw.is_a?(Hash(String, JSON::Any))
        sorted = parsed.raw.as(Hash(String, JSON::Any)).to_a.sort_by(&.[0])
        normalized = JSON.build do |json|
          json.object do
            sorted.each { |k, v| json.field k, v }
          end
        end
      else
        normalized = parsed.to_json
      end
      json_metadata["json_root_type"] = JSON::Any.new(_json_root_type(parsed))
      if parsed.raw.is_a?(Hash(String, JSON::Any))
        keys = parsed.raw.as(Hash(String, JSON::Any)).keys.map(&.to_s).sort!
        json_metadata["json_top_level_keys"] = JSON::Any.new(keys.first(100).map { |k| JSON::Any.new(k) })
      end
    end

    original_chars = normalized.size
    truncated = original_chars > max_chars
    if truncated
      normalized = normalized[0, max_chars]
    end

    meta = {} of String => JSON::Any
    meta["normalized_char_count"] = JSON::Any.new(original_chars)
    meta["truncated"] = JSON::Any.new(truncated)
    json_metadata.each { |k, v| meta[k] = v }
    {normalized, meta}
  end

  # Collect regular non-symlink files without traversing symlink dirs.
  def self._walk_files(root : Path, extensions : Set(String)) : Array(Path)
    found = [] of Path
    Dir.glob("#{root}/**/*", follow_symlinks: false).sort.each do |entry|
      path = Path.new(entry)
      next if path.is_a?(Path) && File.symlink?(path)
      next unless File.file?(path)
      next unless extensions.includes?(path.extension.downcase)
      found << path
    end
    found.sort_by!(&.relative_to(root).to_s)
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
      }.to_json, actor: "local_files.acquisition")
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
    graph.patch_object(cursor.id, current.to_json, actor: "local_files.acquisition")
    graph.get_object(cursor.id) || raise PackError.new("cursor #{cursor.id} vanished")
  end

  # Acquire one bounded, deterministic snapshot of a local directory.
  #
  # Files are committed in sorted relative-path order. A malformed or
  # oversized file records an `ingestion_failure` and creates no acquired
  # objects for that file; valid siblings remain committed. Re-running or
  # taking overlapping snapshots intentionally emits the same acquired
  # identities again — the Activity Normalizer, not this importer, owns dedup.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream import_local_files_fn
  def self.import_local_files_fn(
    graph : Chronicle::GraphProjection,
    root_path : String,
    source_surface_id : String,
    *,
    artifact_store_dir : String = ".activegraph/replay-artifacts",
    replay_mode : String = "artifact",
    is_fixture : Bool = false,
    max_files : Int32 = 1000,
    max_file_bytes : Int32 = 2_000_000,
    max_normalized_chars : Int32 = 8192,
    extensions : Array(String)? = nil,
  ) : Hash(String, JSON::Any)
    unless ImportConstants::REPLAY_MODES.includes?(replay_mode)
      raise PackError.new("unsupported replay_mode #{replay_mode.inspect}")
    end
    if source_surface_id.empty?
      raise PackError.new("source_surface_id is required")
    end
    if max_files < 1 || max_file_bytes < 1 || max_normalized_chars < 1
      raise PackError.new("all import bounds must be positive")
    end

    root = Path.new(root_path).expand(home: true)
    failure_ids = [] of String
    acquired_item_ids = [] of String
    if File.symlink?(root) || !File.exists?(root) || !File.directory?(root)
      failure_ids << _record_failure(
        graph,
        source_surface_id: source_surface_id,
        source_ref: root.to_s,
        error_code: "invalid_root",
        message: "root_path must be an existing, non-symlink directory",
        recoverable: true,
      )
      return {
        "ok"                => JSON::Any.new(false),
        "imported"          => JSON::Any.new(0),
        "failed"            => JSON::Any.new(1),
        "cursor_id"         => JSON::Any.new(nil),
        "acquired_item_ids" => JSON::Any.new([] of JSON::Any),
        "failure_ids"       => JSON::Any.new(failure_ids.map { |failure| JSON::Any.new(failure) }),
        "stopped_at_bound"  => JSON::Any.new(false),
      }
    end

    root = root.expand
    suffixes = (extensions || ImportConstants::DEFAULT_EXTENSIONS).map do |e|
      (e.starts_with?(".") ? e : ".#{e}").downcase
    end.to_set
    candidates = _walk_files(root, suffixes)
    stopped_at_bound = candidates.size > max_files
    candidates = candidates.first(max_files)
    cursor = _find_cursor(graph, source_surface_id)

    candidates.each do |path|
      relative_ref = path.relative_to(root).to_s
      source_ref = path.expand.to_s
      begin
        size = File.size(path)
        if size > max_file_bytes
          raise PackError.new("file is #{size} bytes; limit is #{max_file_bytes}")
        end
        payload = File.open(path, "rb", &.gets_to_end.to_slice)
        if payload.size > max_file_bytes
          raise PackError.new("file grew to #{payload.size} bytes while reading; limit is #{max_file_bytes}")
        end
        text = String.new(payload)
        if text.valid_encoding?.nil?
          raise PackError.new("file is not valid UTF-8")
        end

        begin
          normalized, norm_meta = _normalize_content(text, suffix: path.extension.downcase, max_chars: max_normalized_chars)
        rescue ex : JSON::ParseException
          raise PackError.new("malformed JSON at line #{ex.line_number}, column #{ex.column_number}")
        end

        replay_ref, replay_hash = _replay_reference(text, replay_mode: replay_mode, artifact_store_dir: artifact_store_dir)
        source_hash = _sha256(payload)
      rescue ex : PackError | IO::Error
        code = path.extension.downcase == ".json" && ex.message.try(&.includes?("JSON")) ? "invalid_json" : "invalid_file"
        failure_ids << _record_failure(
          graph,
          source_surface_id: source_surface_id,
          source_ref: source_ref,
          provider_item_id: relative_ref,
          error_code: code,
          message: ex.message.to_s,
          recoverable: ex.is_a?(IO::Error),
          metadata: {"relative_path" => JSON::Any.new(relative_ref)},
        )
        next
      end

      acquired = graph.add_object("acquired_item", {
        "source_surface_id"   => JSON::Any.new(source_surface_id),
        "provider_item_id"    => JSON::Any.new(relative_ref),
        "dedup_key"           => JSON::Any.new(relative_ref),
        "source_ref"          => JSON::Any.new(source_ref),
        "source_hash"         => JSON::Any.new(source_hash),
        "provider_time"       => JSON::Any.new(nil),
        "replay_mode"         => JSON::Any.new(replay_mode),
        "replay_payload_ref"  => JSON::Any.new(replay_ref),
        "replay_payload_hash" => JSON::Any.new(replay_hash),
        "media_type"          => JSON::Any.new(_media_type(path.extension.downcase)),
        "importer_id"         => JSON::Any.new(ImportConstants::IMPORTER_ID),
        "importer_version"    => JSON::Any.new(ImportConstants::IMPORTER_VERSION),
      }.to_json, actor: "local_files.acquisition")
      graph.add_object("acquired_content", {
        "acquired_item_id"    => JSON::Any.new(acquired.id),
        "normalized_content"  => JSON::Any.new(normalized),
        "normalized_metadata" => JSON::Any.new({
          "relative_path"  => JSON::Any.new(relative_ref),
          "extension"      => JSON::Any.new(path.extension.downcase),
          "byte_size"      => JSON::Any.new(payload.size),
          "content_sha256" => JSON::Any.new(source_hash),
        }.merge(norm_meta)),
        "source_category" => JSON::Any.new("local_knowledge"),
        "connection_path" => JSON::Any.new("local"),
        "is_fixture"      => JSON::Any.new(is_fixture),
      }.to_json, actor: "local_files.acquisition")
      acquired_item_ids << acquired.id
      cursor = _advance_cursor(graph, cursor, source_surface_id, relative_ref)
    end

    {
      "ok"                => JSON::Any.new(failure_ids.empty?),
      "imported"          => JSON::Any.new(acquired_item_ids.size),
      "failed"            => JSON::Any.new(failure_ids.size),
      "cursor_id"         => cursor.nil? ? JSON::Any.new(nil) : JSON::Any.new(cursor.id),
      "acquired_item_ids" => JSON::Any.new(acquired_item_ids.map { |item| JSON::Any.new(item) }),
      "failure_ids"       => JSON::Any.new(failure_ids.map { |failure| JSON::Any.new(failure) }),
      "stopped_at_bound"  => JSON::Any.new(stopped_at_bound),
    }
  end

  # Registered capability wrapper for import_local_files_fn.
  @[Chronicle::Packs::Annotations::Tool(name: "import_local_files", description: "Acquire a bounded snapshot of UTF-8 text, Markdown, and JSON files. Emits Activity Normalizer acquired-item/content records; it does not deduplicate, extract candidates, or promote state.")]
  def import_local_files_tool(args : String) : String
    input = JSON.parse(args).as_h
    bound_graph = bound_graph_or_raise
    result = import_local_files_fn(
      bound_graph,
      input["root_path"]?.try(&.as_s?) || "",
      input["source_surface_id"]?.try(&.as_s?) || "",
      artifact_store_dir: input["artifact_store_dir"]?.try(&.as_s?) || ".activegraph/replay-artifacts",
      replay_mode: input["replay_mode"]?.try(&.as_s?) || "artifact",
      is_fixture: input["is_fixture"]?.try(&.as_bool?) || false,
      max_files: input["max_files"]?.try(&.as_i?) || 1000,
      max_file_bytes: input["max_file_bytes"]?.try(&.as_i?) || 2_000_000,
      max_normalized_chars: input["max_normalized_chars"]?.try(&.as_i?) || 8192,
    )
    result.to_json
  end

  class_property bound_graph : Chronicle::GraphProjection? = nil

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise PackError.new(
      "local_files tools require a bound graph (set LocalFiles.bound_graph)"
    )
  end
end

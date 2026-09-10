require "json"
require "digest"

module Chronicle::Packs::Evolution
  # Author-frame assembly enforcement (docs/llm-author-design.md §3-§4).
  #
  # The LLM author itself is unbuilt; these primitives turn the design's
  # asserted trust boundaries into ENFORCED ones: the taint recompute a
  # corrupted drafting record cannot launder, and the structured-field
  # charset check that keeps "structured" from meaning "prose we are
  # calling structured". Nothing here reads or writes candidate code,
  # imports anything, or touches a model. Pure graph reads and regex.
  module AuthorFrame
    # The one repo path an authored pack may never target. The charter is
    # the author's system prompt: the single fully-trusted origin in the
    # frame (§3a). Its trust is human-PR-only.
    AUTHOR_CHARTER_FILENAME = "author_charter.md"

    # The charter's text, repo-shipped and version-controlled. Embedded so
    # the port is self-contained; byte-identical to the pinned vendor file.
    CHARTER_TEXT = {{ read_file("#{__DIR__}/../../../vendor/activegraph-packs/packs/evolution/author_charter.md") }}

    # The manifest identifier charset (activegraph.packs.manifest._NAME_RE),
    # pinned here so the pack validates admitted structured identifiers
    # against the exact shape the runtime enforces on pack/provider/
    # capability names.
    MANIFEST_NAME_RE = /^[a-z][a-z0-9_]{1,63}$/

    # A dotted Python identifier: RuntimeError, a.b.C. No spaces, no
    # punctuation prose can hide in, so an exception_type field cannot
    # smuggle a sentence.
    EXCEPTION_TYPE_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/

    RISK_CLASSES = Set{"low", "medium", "high", "critical"}

    # The closed, pure-data frame the host may hand to an AuthorService. The
    # graph ids which crossed the boundary are retained separately for the
    # sealed drafting_context record; no graph handle or capability can enter
    # the author boundary.
    record Assembly,
      charter : String,
      charter_hash : String,
      gap_id : String,
      gap_fields : Hash(String, JSON::Any),
      surface_packs : Array(String),
      surface_object_types : Array(String),
      owner_text : Array(String),
      structured_fields : Array(String),
      surface_sources : Array(String),
      owner_input_ids : Array(String),
      injection_flags : Array(String) do
      def frame : Hash(String, JSON::Any)
        {
          "charter"    => JSON::Any.new(charter),
          "gap_fields" => JSON::Any.new(gap_fields),
          "surface"    => JSON::Any.new({
            "packs"        => JSON::Any.new(surface_packs.map { |name| JSON::Any.new(name) }),
            "object_types" => JSON::Any.new(surface_object_types.map { |name| JSON::Any.new(name) }),
          }),
          "owner_text" => JSON::Any.new(owner_text.map { |text| JSON::Any.new(text) }),
        }
      end
    end

    def self._is_name(value : JSON::Any?) : Bool
      str = value.try(&.as_s?)
      !str.nil? && str.matches?(MANIFEST_NAME_RE)
    end

    def self._is_exception_type(value : JSON::Any?) : Bool
      str = value.try(&.as_s?)
      !str.nil? && str.size <= 128 && str.matches?(EXCEPTION_TYPE_RE)
    end

    def self._is_count(value : JSON::Any?) : Bool
      !value.nil? && value.raw.is_a?(Int64) || !value.nil? && value.raw.is_a?(Int32)
    end

    # Python `!r` repr for strings: single-quoted (upstream message format).
    private def self._repr(s : String) : String
      "'" + s.gsub("\\", "\\\\").gsub("'", "\\'") + "'"
    end

    # The CLOSED set of field paths §3b admits from a gap's evidence chain,
    # each bound to the charset that keeps it an identifier.
    ADMISSIBLE_FIELD_PATHS = Set{"provider_name", "capability_name", "risk_class", "exception_type", "failure_count", "n"}

    def self._field_validators
      {
        "provider_name"   => ->(v : JSON::Any?) { _is_name(v) },
        "capability_name" => ->(v : JSON::Any?) { _is_name(v) },
        "risk_class"      => ->(value : JSON::Any?) { value.try(&.as_s?).try { |risk| RISK_CLASSES.includes?(risk) } || false },
        "exception_type"  => ->(v : JSON::Any?) { _is_exception_type(v) },
        "failure_count"   => ->(v : JSON::Any?) { _is_count(v) },
        "n"               => ->(v : JSON::Any?) { _is_count(v) },
      }
    end

    # The charter's text and its `sha256:` pin (§3a).
    def self.charter_text_and_hash : {String, String}
      {CHARTER_TEXT, "sha256:" + Digest::SHA256.hexdigest(CHARTER_TEXT)}
    end

    # Assemble the four-section author frame exactly from the allowed
    # origins: charter, identifier-shaped gap evidence, pack.loaded surface,
    # and content from verified owners. Everything else in the graph is
    # deliberately unreadable from this path.
    def self.assemble(graph : Chronicle::GraphProjection, gap_id : String, approver_roles : Array(String) = ["owner", "admin"]) : Assembly
      gap = graph.get_object(gap_id)
      if gap.nil? || gap.type != "capability_gap"
        raise AuthorRefusal.new("no capability_gap #{_repr(gap_id)}")
      end

      charter, charter_hash = charter_text_and_hash
      gap_data = JSON.parse(gap.data)
      gap_fields, structured_fields = _structured_evidence(graph, gap_data["evidence_refs"]?.try(&.as_a) || [] of JSON::Any)
      surface_packs, surface_object_types, surface_sources = _loaded_surface(graph)
      owner_text, owner_input_ids, flags = _verified_owner_inputs(graph, approver_roles)

      Assembly.new(
        charter, charter_hash, gap.id, gap_fields, surface_packs,
        surface_object_types, owner_text, structured_fields, surface_sources,
        owner_input_ids, flags,
      )
    end

    private def self._structured_evidence(graph : Chronicle::GraphProjection, evidence_ids : Array(JSON::Any)) : {Hash(String, JSON::Any), Array(String)}
      gap_fields = {} of String => JSON::Any
      structured_fields = [] of String
      evidence_ids.each do |evidence_id|
        object_id = evidence_id.as_s
        evidence = graph.get_object(object_id)
        next if evidence.nil?

        evidence_data = JSON.parse(evidence.data).as_h
        ADMISSIBLE_FIELD_PATHS.to_a.sort.each do |field_path|
          next unless evidence_data.has_key?(field_path)
          entry = "#{object_id}:#{field_path}"
          next unless validate_structured_fields(graph, [entry]).empty?
          structured_fields << entry
          gap_fields[entry] = evidence_data[field_path]
        end
      end
      {gap_fields, structured_fields}
    end

    private def self._loaded_surface(graph : Chronicle::GraphProjection) : {Array(String), Array(String), Array(String)}
      surface_packs = [] of String
      surface_object_types = [] of String
      surface_sources = [] of String
      graph.events.each do |event|
        next unless event.type == "pack.loaded"
        payload = JSON.parse(event.payload)
        name = payload["name"]?.try(&.as_s?)
        if name && !surface_packs.includes?(name)
          surface_packs << name
          surface_sources << "pack:#{name}"
        end
        (payload["object_types"]?.try(&.as_a) || [] of JSON::Any).each do |object_type|
          name = object_type.as_s?
          surface_object_types << name if name && !surface_object_types.includes?(name)
        end
      end
      {surface_packs, surface_object_types, surface_sources}
    end

    private def self._verified_owner_inputs(graph : Chronicle::GraphProjection, approver_roles : Array(String)) : {Array(String), Array(String), Array(String)}
      owner_text = [] of String
      owner_input_ids = [] of String
      flags = Set(String).new
      graph.objects(type: "chat_input").each do |input|
        input_data = JSON.parse(input.data)
        sender = input_data["user_ref"]?.try(&.as_s?) || ""
        next if sender.empty?
        principal = IdentityAuth.lookup_principal_fn(graph, sender)
        role = principal.try(&.["role"]?.try(&.as_s?))
        next unless role && approver_roles.includes?(role)

        content = input_data["content"]?.try(&.as_s?) || ""
        hits = ToolGateway::Untrusted.scan_for_injection(content)
        flags.concat(hits)
        (input_data["injection_flags"]?.try(&.as_a) || [] of JSON::Any).each { |flag| flags << flag.as_s }
        owner_input_ids << input.id
        owner_text << ToolGateway::Untrusted.wrap_untrusted(content, hits)
      end
      {owner_text, owner_input_ids, flags.to_a.sort}
    end

    # Charset-check every admitted structured field (§3b/§6).
    #
    # Each entry is "<object_id>:<field_path>". A field is admissible only
    # when its field path is in the §3b allow-list AND the value it
    # references on the graph object matches that field's charset. Returns
    # violation strings; empty means clean.
    def self.validate_structured_fields(graph : Chronicle::GraphProjection, structured_fields : Array(String)) : Array(String)
      validators = _field_validators
      violations = [] of String
      structured_fields.each do |entry|
        parts = entry.split(":", 2)
        if parts.size < 2 || parts[1].empty?
          violations << "structured field #{_repr(entry)} is not '<object_id>:<field_path>'"
          next
        end
        object_id, field_path = parts
        validator = validators[field_path]?
        if validator.nil?
          violations << "#{entry}: field path #{_repr(field_path)} is not admissible as structured evidence (allowed: #{ADMISSIBLE_FIELD_PATHS.to_a.sort.join(", ")})"
          next
        end
        obj = graph.get_object(object_id)
        if obj.nil?
          violations << "#{entry}: object #{_repr(object_id)} not in the graph"
          next
        end
        value = JSON.parse(obj.data)[field_path]?
        unless validator.call(value)
          str = value.try(&.as_s?)
          rendered = str.nil? ? value.inspect : _repr(str)
          violations << "#{entry}: value #{rendered} fails the #{_repr(field_path)} charset (prose-shaped text is not a structured identifier)"
        end
      end
      violations
    end

    # Every GRAPH object a drafting record admitted: the objects behind the
    # structured fields (§3b), the owner inputs (§3d), and the gap. Surface
    # sources (§3c) are repo-shipped paths, not graph objects, so they carry
    # no taint and are not consulted.
    def self._admitted_object_ids(record_data : Hash(String, JSON::Any)) : Array(String)
      ids = [] of String
      (record_data["structured_fields"]?.try(&.as_a) || [] of JSON::Any).each do |entry|
        object_id = entry.as_s.split(":", 2)[0]?
        ids << object_id if object_id && !object_id.empty?
      end
      (record_data["owner_input_ids"]?.try(&.as_a) || [] of JSON::Any).each do |i|
        ids << i.as_s
      end
      gap_id = record_data["gap_id"]?.try(&.as_s?)
      ids << gap_id if gap_id && !gap_id.empty?
      ids
    end

    # The §4 analog of gap-lineage's deterministic taint union.
    #
    # Recomputes the injection-flag union over every object the drafting
    # record ADMITTED, read fresh from the graph by id, ignoring any
    # `injection_flags` value the record itself stores. Returns the sorted
    # union.
    def self.recompute_drafting_taint(graph : Chronicle::GraphProjection, record_data : Hash(String, JSON::Any)) : Array(String)
      flags = Set(String).new
      _admitted_object_ids(record_data).each do |object_id|
        obj = graph.get_object(object_id)
        if obj
          (JSON.parse(obj.data)["injection_flags"]?.try(&.as_a) || [] of JSON::Any).each do |flag|
            flags << flag.as_s
          end
        end
      end
      # Owner text (§3d) is the one free-text origin admitted, so it is
      # ALSO content-scanned here: the tripwire flags the record even when
      # the owner input arrived without a pre-recorded flag.
      (record_data["owner_input_ids"]?.try(&.as_a) || [] of JSON::Any).each do |owner_id|
        obj = graph.get_object(owner_id.as_s)
        if obj
          content = JSON.parse(obj.data)["content"]?.try(&.as_s?) || ""
          ToolGateway::Untrusted.scan_for_injection(content).each { |flag| flags << flag }
        end
      end
      flags.to_a.sort
    end
  end
end

require "json"

module Chronicle::Packs::Entity
  # Entity behaviors. Ported from upstream packs/entity/behaviors.py.
  #
  # entity_registry_recorder indexes entities for O(1) lookup; entity_extractor
  # (off by default) and entity_mention_from_annotation produce mentions;
  # entity_resolver links mentions to canonical entities; merge_candidate_detector
  # finds likely duplicates.

  # ------------------------------------------------------------------ registry

  # One registry entry for a canonical entity (name/alias/identifier index).
  # An immutable value object — struct + JSON::Serializable.
  struct EntityRegistryEntry
    include JSON::Serializable

    getter id : String
    getter name : String
    getter aliases : Array(String)
    getter identifiers : Hash(String, JSON::Any)
    getter entity_type : String

    def initialize(@id : String, @name : String, @aliases : Array(String), @identifiers : Hash(String, JSON::Any), @entity_type : String)
    end
  end

  class_property entity_registry = {} of String => EntityRegistryEntry
  class_property alias_index = {} of String => Array(String)

  def self._normalize(value : String) : String
    value.strip.downcase
  end

  def self._add_to_alias_index(entity_id : String, name : String, aliases : Array(String)) : Nil
    ([name] + aliases).each do |label|
      norm = _normalize(label)
      next if norm.empty?

      entry = (alias_index[norm]? || [] of String)
      alias_index[norm] = entry unless entry.includes?(entity_id)
      alias_index[norm] << entity_id unless alias_index[norm].includes?(entity_id)
    end
  end

  def self.clear_entity_registry : Nil
    self.entity_registry = {} of String => EntityRegistryEntry
    self.alias_index = {} of String => Array(String)
  end

  # ------------------------------------------------------------------ similarity helpers

  # The similarity verdict between two entities.
  struct SimilarityResult
    getter score : Float64
    getter reasons : Array(String)

    def initialize(@score : Float64, @reasons : Array(String))
    end
  end

  # Normalized edit distance: 1.0 = identical, 0.0 = completely different.
  def self.edit_distance_ratio(a : String, b : String) : Float64
    a = a.downcase
    b = b.downcase
    return 1.0 if a == b
    return 0.0 if a.empty? || b.empty?

    m = a.size
    n = b.size
    dp = (0..n).to_a
    (1..m).each do |row|
      new_dp = [row] of Int32
      (1..n).each do |col|
        cost = a[row - 1] == b[col - 1] ? 0 : 1
        new_dp << {new_dp[-1] + 1, dp[col] + 1, dp[col - 1] + cost}.min
      end
      dp = new_dp
    end
    distance = dp[n]
    max_len = Math.max(m, n)
    1.0 - (distance.to_f / max_len)
  end

  # Any exact (case-insensitive) identifier match is definitive (1.0).
  def self.identifier_overlap_score(ids_a : Hash(String, JSON::Any), ids_b : Hash(String, JSON::Any)) : Float64
    return 0.0 if ids_a.empty? || ids_b.empty?

    ids_a.each do |key, value_a|
      value_b = ids_b[key]?
      if value_b && value_a.as_s.downcase == value_b.as_s.downcase
        return 1.0
      end
    end
    0.0
  end

  # Similarity score and reasons between two entities.
  def self.compute_similarity(
    name_a : String,
    aliases_a : Array(String),
    ids_a : Hash(String, JSON::Any),
    name_b : String,
    aliases_b : Array(String),
    ids_b : Hash(String, JSON::Any),
  ) : SimilarityResult
    reasons = [] of String

    id_score = identifier_overlap_score(ids_a, ids_b)
    return SimilarityResult.new(1.0, ["exact_identifier_match"]) if id_score >= 1.0

    labels_a = [_normalize(name_a)] + aliases_a.map { |alias_a| _normalize(alias_a) }
    labels_b = [_normalize(name_b)] + aliases_b.map { |alias_b| _normalize(alias_b) }

    max_name_score = 0.0
    labels_a.each do |label_a|
      labels_b.each do |label_b|
        if label_a == label_b
          return SimilarityResult.new(1.0, ["name_exact_match"])
        end
        score = edit_distance_ratio(label_a, label_b)
        max_name_score = score if score > max_name_score
      end
    end

    if max_name_score >= 0.9
      reasons << "name_near_match"
    elsif max_name_score >= 0.7
      reasons << "name_partial_match"
    end

    SimilarityResult.new(Math.max(id_score, max_name_score), reasons)
  end

  # ------------------------------------------------------------------ extraction heuristics

  # Regexes and org suffixes for mention extraction. Nested module so the
  # DSL's `pack` macro (which assumes every direct constant is a type)
  # doesn't trip over the regex/set constants.
  module Extraction
    EMAIL_RE            = /\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b/
    GITHUB_RE           = /github\.com\/([A-Za-z0-9\-_]+\/[A-Za-z0-9\-_.]+)/
    CAPITALIZED_NAME_RE = /\b([A-Z][a-z]{1,20}(?:\s+[A-Z][a-z]{1,20}){1,4})\b/
    ORG_SUFFIXES        = Set{
      "Inc", "LLC", "Ltd", "Corp", "Corporation", "Company", "Co",
      "Group", "Foundation", "Institute", "Labs", "Lab", "Technologies",
      "Tech", "Systems", "Solutions", "Ventures", "Capital", "Partners",
    }
  end

  # Shared-layer annotation kinds -> entity types.
  module EntityAnnotationKinds
    ENTITY_TYPE_BY_KIND = {
      "person"       => "person",
      "organization" => "organization",
      "place"        => "other",
      "product"      => "product",
      "proper_noun"  => "other",
      "handle"       => "person",
      "email"        => "person",
      "url"          => "other",
      "other"        => "other",
    }
  end

  # A mention candidate produced by the extraction heuristics. JSON keys
  # match EntityMention so the extractor can serialize it straight to the
  # graph (the @[ObjectType] validator round-trips the defaults).
  struct MentionCandidate
    include JSON::Serializable

    getter text : String
    getter source_id : String
    getter entity_type_hint : String?
    getter confidence : Float64
    getter context_snippet : String
    getter extraction_method : String
    getter metadata : Hash(String, JSON::Any)

    def initialize(
      @text : String,
      @source_id : String,
      @entity_type_hint : String?,
      @confidence : Float64,
      @context_snippet : String,
      @extraction_method : String,
      @metadata : Hash(String, JSON::Any),
    )
    end
  end

  # Extract entity mention candidates from text using heuristics.
  def self._extract_mentions_from_text(
    text : String,
    source_id : String,
    settings : EntitySettings,
    max_mentions : Int32,
  ) : Array(MentionCandidate)
    mentions = [] of MentionCandidate
    _extract_email_mentions(text, source_id, settings, max_mentions, mentions)
    _extract_name_mentions(text, source_id, settings, max_mentions, mentions)
    _extract_repo_mentions(text, source_id, settings, max_mentions, mentions)
    mentions
  end

  private def self._extract_email_mentions(
    text : String,
    source_id : String,
    settings : EntitySettings,
    max_mentions : Int32,
    mentions : Array(MentionCandidate),
  ) : Nil
    return if !settings.extract_persons?

    text.scan(Extraction::EMAIL_RE).each do |match|
      email = match[0]
      local_part = email.split('@')[0].gsub('.', ' ').gsub('_', ' ').split(' ').map(&.capitalize).join(' ')
      start = Math.max(0, match.begin(0) - 30)
      fin = Math.min(text.size, match.end(0) + 30)
      mentions << MentionCandidate.new(
        text: email, source_id: source_id, entity_type_hint: "person",
        confidence: 0.85, context_snippet: text[start, fin - start],
        extraction_method: "regex",
        metadata: {"normalized_name" => JSON::Any.new(local_part), "email" => JSON::Any.new(email)},
      )
      break if mentions.size >= max_mentions
    end
  end

  private def self._extract_name_mentions(
    text : String,
    source_id : String,
    settings : EntitySettings,
    max_mentions : Int32,
    mentions : Array(MentionCandidate),
  ) : Nil
    return if !settings.extract_persons? && !settings.extract_organizations?

    seen = Set(String).new
    text.scan(Extraction::CAPITALIZED_NAME_RE).each do |match|
      name = match[1].strip
      next if seen.includes?(name) || name.size < 4

      seen.add(name)
      words = name.split(' ')
      last_word = words.last? || ""
      if last_word.in?(Extraction::ORG_SUFFIXES)
        entity_type = "organization"
        confidence = 0.75
        next if !settings.extract_organizations?
      else
        entity_type = "person"
        confidence = 0.65
        next if !settings.extract_persons?
      end

      start = Math.max(0, match.begin(1) - 30)
      fin = Math.min(text.size, match.end(1) + 30)
      mentions << MentionCandidate.new(
        text: name, source_id: source_id, entity_type_hint: entity_type,
        confidence: confidence, context_snippet: text[start, fin - start],
        extraction_method: "heuristic",
        metadata: {} of String => JSON::Any,
      )
      break if mentions.size >= max_mentions
    end
  end

  private def self._extract_repo_mentions(
    text : String,
    source_id : String,
    settings : EntitySettings,
    max_mentions : Int32,
    mentions : Array(MentionCandidate),
  ) : Nil
    return if !settings.extract_urls_as_entities?

    text.scan(Extraction::GITHUB_RE).each do |match|
      repo = match[1]
      mentions << MentionCandidate.new(
        text: repo, source_id: source_id, entity_type_hint: "repo",
        confidence: 0.9, context_snippet: match[0],
        extraction_method: "regex",
        metadata: {"github_url" => JSON::Any.new("https://github.com/#{repo}")},
      )
      break if mentions.size >= max_mentions
    end
  end

  # ------------------------------------------------------------------ behaviors

  # Index a new entity in the local registry for fast lookup.
  @[Chronicle::Packs::Annotations::Behavior(name: "entity_registry_recorder", on: ["object.created"], where: {"type" => "entity"})]
  def entity_registry_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EntitySettings) : Nil
    payload = JSON.parse(event.payload)
    entity_id = payload["id"]?.try(&.as_s?)
    return if entity_id.nil?

    data = payload["data"]?
    return if data.nil?

    name = data["name"]?.try(&.as_s?) || ""
    aliases = data["aliases"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    identifiers = data["identifiers"]?.try(&.as_h) || {} of String => JSON::Any
    entity_type = data["entity_type"]?.try(&.as_s?) || "other"

    entity_registry[entity_id] = EntityRegistryEntry.new(entity_id, name, aliases, identifiers, entity_type)
    _add_to_alias_index(entity_id, name, aliases)
  end

  # Extract entity mentions from a source (disabled by default; shared
  # extraction contract owns mentions — ADR 0026 step 4).
  @[Chronicle::Packs::Annotations::Behavior(name: "entity_extractor", on: ["object.created"], where: {"type" => "source"}, creates: ["entity_mention"])]
  def entity_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EntitySettings) : Nil
    return if !settings.extract_from_raw_sources?

    payload = JSON.parse(event.payload)
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?

    data = payload["data"]?
    content = data.try(&.["content"]?.try(&.as_s?)) || ""
    frame_id = data.try(&.["frame_id"]?.try(&.as_s?))
    return if content.empty? || content.strip.size < 4

    candidates = _extract_mentions_from_text(content, source_id, settings, settings.max_mentions_per_source)
    candidates.each do |candidate|
      next if candidate.confidence < settings.extraction_min_confidence

      mention_data = JSON.parse(candidate.to_json).as_h
      mention_data["frame_id"] = JSON::Any.new(frame_id) if frame_id
      mention = graph.add_object("entity_mention", mention_data.to_json)

      begin
        graph.add_relation(source_id, mention.id, "mentions")
      rescue
      end
    end
  end

  # Mint EntityMention objects from the shared layer's entity_mention
  # annotations (canonical resolution stays in entity_resolver).
  @[Chronicle::Packs::Annotations::Behavior(name: "entity_mention_from_annotation", on: ["object.created"], where: {"type" => "semantic_annotation", "data.facet" => "entity_mention", "data.status" => "active"}, creates: ["entity_mention"])]
  def entity_mention_from_annotation(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EntitySettings) : Nil
    return if !settings.consume_entity_mention_annotations?

    if context = _annotation_context(JSON.parse(event.payload), settings, graph)
      _create_annotation_mention(graph, context[:text], context[:evidence_id], context[:entity_type_hint], context[:confidence], context[:selector], context[:metadata])
    end
  end

  # Validate and extract an entity_mention annotation's context, or nil.
  def self._annotation_context(
    payload : JSON::Any,
    settings : EntitySettings,
    graph : Chronicle::GraphProjection,
  ) : NamedTuple(annotation_id: String, text: String, entity_type_hint: String, confidence: Float64, evidence_id: String, selector: Hash(String, JSON::Any), metadata: Hash(String, JSON::Any))?
    data = payload["data"]?
    return nil if data.nil?
    return nil unless (data["facet"]?.try(&.as_s?)) == "entity_mention"
    return nil unless (data["status"]?.try(&.as_s?)) == "active"

    confidence = data["confidence"]?.try(&.as_f?) || 0.0
    return nil if confidence < settings.extraction_min_confidence

    annotation_id = payload["id"]?.try(&.as_s?)
    return nil if annotation_id.nil?

    # Dedup by annotation id.
    graph.objects(type: "entity_mention").each do |existing|
      meta = _as_h(JSON.parse(existing.data)["metadata"]?)
      return nil if meta["annotation_id"]?.try(&.as_s?) == annotation_id
    end

    body = _as_h(data["body"]?)
    text = _as_s(body["text"]?, "")
    return nil if text.empty?

    kind = _as_s(body["kind"]?, "other")
    evidence_id = _as_s(data["evidence_id"]?, "")
    selector = _as_h(data["selector"]?)
    metadata = _annotation_metadata(data.as_h, body, kind, text, annotation_id)

    {
      annotation_id:    annotation_id,
      text:             text,
      entity_type_hint: EntityAnnotationKinds::ENTITY_TYPE_BY_KIND[kind]? || "other",
      confidence:       confidence,
      evidence_id:      evidence_id,
      selector:         selector,
      metadata:         metadata,
    }
  end

  # Build the entity_mention metadata for a shared-layer annotation.
  def self._annotation_metadata(
    data : Hash(String, JSON::Any),
    body : Hash(String, JSON::Any),
    kind : String,
    text : String,
    annotation_id : String,
  ) : Hash(String, JSON::Any)
    metadata = {"annotation_id" => JSON::Any.new(annotation_id), "kind" => JSON::Any.new(kind)}
    if identity = data["annotation_identity"]?
      metadata["annotation_identity"] = identity
    end
    normalized = body["normalized"]?.try(&.as_s?) || text
    if kind == "email"
      local_part = text.split('@')[0].gsub('.', ' ').gsub('_', ' ').split(' ').map(&.capitalize).join(' ')
      metadata["normalized_name"] = JSON::Any.new(local_part)
      metadata["email"] = JSON::Any.new(normalized)
    elsif normalized != text
      metadata["normalized_name"] = JSON::Any.new(normalized)
    end
    metadata
  end

  # Create an entity_mention from an annotation and link it to its evidence.
  def self._create_annotation_mention(
    graph : Chronicle::GraphProjection,
    text : String,
    evidence_id : String,
    entity_type_hint : String,
    confidence : Float64,
    selector : Hash(String, JSON::Any),
    metadata : Hash(String, JSON::Any),
  ) : Nil
    mention_data = JSON.build do |json|
      json.object do
        json.field "text", text
        json.field "source_id", evidence_id
        json.field "entity_type_hint", entity_type_hint
        json.field "confidence", confidence
        json.field "context_snippet", selector["exact"]?.try(&.as_s?) || text
        json.field "extraction_method", "annotation"
        json.field "metadata", JSON::Any.new(metadata)
      end
    end
    mention = graph.add_object("entity_mention", mention_data)

    begin
      graph.add_relation(evidence_id, mention.id, "mentions")
    rescue
    end
  end

  # Match an entity mention to an existing entity or create a new one.
  @[Chronicle::Packs::Annotations::Behavior(name: "entity_resolver", on: ["object.created"], where: {"type" => "entity_mention"}, creates: ["entity"])]
  def entity_resolver(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EntitySettings) : Nil
    payload = JSON.parse(event.payload)
    mention_id = payload["id"]?.try(&.as_s?)
    return if mention_id.nil?

    data = payload["data"]?
    return if data.nil?

    _resolve_mention(data, graph, mention_id, settings)
  end

  # Whether a best-match result clears the link-vs-create threshold, and
  # which entity to link (nil means create a new one).
  def self._best_match_result(best_entity_id : String?, best_score : Float64, settings : EntitySettings) : String?
    return nil if best_entity_id.nil?
    return best_entity_id if best_score >= settings.resolution_similarity_threshold
    return best_entity_id if settings.auto_accept_exact_identifier_match? && best_score >= 1.0

    nil
  end

  # JSON::Any to hash, empty when absent or not a hash.
  def self._as_h(value : JSON::Any?) : Hash(String, JSON::Any)
    value.try(&.as_h) || {} of String => JSON::Any
  end

  # JSON::Any to string, default when absent or not a string.
  def self._as_s(value : JSON::Any?, default : String) : String
    value.try(&.as_s?) || default
  end

  # Patch a mention's entity_id and link it with a refers_to relation.
  def self._link_mention(graph : Chronicle::GraphProjection, mention_id : String, current : String, entity_id : String) : Nil
    merged = JSON.parse(current).as_h
    merged["entity_id"] = JSON::Any.new(entity_id)
    begin
      graph.patch_object(mention_id, merged.to_json)
    rescue
    end
    begin
      graph.add_relation(mention_id, entity_id, "refers_to")
    rescue
    end
  end

  # Resolve one mention: link it to the best matching entity or create a
  # new entity for it.
  def self._resolve_mention(data : JSON::Any, graph : Chronicle::GraphProjection, mention_id : String, settings : EntitySettings) : Nil
    mention_text = data["text"]?.try(&.as_s?) || ""
    return if mention_text.empty?

    mention_confidence = data["confidence"]?.try(&.as_f?) || 0.5
    mention_meta = _as_h(data["metadata"]?)
    entity_type_hint = data["entity_type_hint"]?.try(&.as_s?) || "other"
    source_id = data["source_id"]?.try(&.as_s?) || ""
    frame_id = data["frame_id"]?.try(&.as_s?)

    mention_ids = {} of String => JSON::Any
    if email = mention_meta["email"]?
      mention_ids["email"] = email
    end
    mention_name = mention_meta["normalized_name"]?.try(&.as_s?) || mention_text

    best_entity_id, best_score = _find_best_match(mention_name, mention_text, mention_ids, settings)

    # Link to existing entity or create a new one.
    if match = _best_match_result(best_entity_id, best_score, settings)
      _link_mention(graph, mention_id, data.to_json, match)
    else
      aliases = [] of String
      if (normalized = mention_meta["normalized_name"]?.try(&.as_s?)) && normalized != mention_text
        aliases << normalized
      end

      entity_data = _build_new_entity_data(mention_name, entity_type_hint, mention_ids, mention_confidence, source_id, frame_id, mention_id, aliases)
      new_entity = graph.add_object("entity", entity_data)

      _link_mention(graph, mention_id, data.to_json, new_entity.id)
    end
  end

  # Find the best matching entity for a mention (alias index first, then
  # identifier overlap across the registry).
  def self._find_best_match(
    mention_name : String,
    mention_text : String,
    mention_ids : Hash(String, JSON::Any),
    settings : EntitySettings,
  ) : {String?, Float64}
    best_entity_id : String? = nil
    best_score = 0.0
    mention_norm = _normalize(mention_text)

    alias_candidates = alias_index[mention_norm]? || [] of String
    alias_candidates.each do |entity_id|
      entry = entity_registry[entity_id]?
      next if entry.nil?

      sim = compute_similarity(mention_name, [mention_text], mention_ids, entry.name, entry.aliases, entry.identifiers)
      if sim.score > best_score
        best_score = sim.score
        best_entity_id = entity_id
      end
      break if settings.auto_accept_exact_identifier_match? && sim.score >= 1.0
    end

    if best_score < settings.resolution_similarity_threshold && !mention_ids.empty?
      entity_registry.each do |entity_id, entry|
        next if alias_candidates.includes?(entity_id)

        id_score = identifier_overlap_score(mention_ids, entry.identifiers)
        if id_score > best_score
          best_score = id_score
          best_entity_id = entity_id
        end
        break if settings.auto_accept_exact_identifier_match? && id_score >= 1.0
      end
    end

    {best_entity_id, best_score}
  end

  # Build the JSON data for a new entity created from a mention.
  def self._build_new_entity_data(
    mention_name : String,
    entity_type_hint : String,
    mention_ids : Hash(String, JSON::Any),
    mention_confidence : Float64,
    source_id : String,
    frame_id : String?,
    mention_id : String,
    aliases : Array(String),
  ) : String
    JSON.build do |json|
      json.object do
        json.field "name", mention_name
        json.field "entity_type", entity_type_hint
        json.field "aliases", aliases
        json.field "identifiers", JSON::Any.new(mention_ids)
        json.field "confidence", mention_confidence
        json.field "source_ids", source_id.empty? ? [] of String : [source_id]
        json.field "frame_id", frame_id if frame_id
        json.field "metadata", {"created_by" => JSON::Any.new("entity_resolver"), "mention_id" => JSON::Any.new(mention_id)}
      end
    end
  end

  # Detect entities that may be duplicates of a newly created entity.
  @[Chronicle::Packs::Annotations::Behavior(name: "merge_candidate_detector", on: ["object.created"], where: {"type" => "entity"}, creates: ["merge_candidate"])]
  def merge_candidate_detector(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : EntitySettings) : Nil
    payload = JSON.parse(event.payload)
    new_entity_id = payload["id"]?.try(&.as_s?)
    return if new_entity_id.nil?

    data = payload["data"]?
    return if data.nil?

    new_name = data["name"]?.try(&.as_s?) || ""
    new_aliases = data["aliases"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    new_ids = data["identifiers"]?.try(&.as_h) || {} of String => JSON::Any
    frame_id = data["frame_id"]?.try(&.as_s?)

    entity_registry.each do |existing_id, entry|
      next if existing_id == new_entity_id

      sim = compute_similarity(new_name, new_aliases, new_ids, entry.name, entry.aliases, entry.identifiers)
      next if sim.score < settings.merge_candidate_threshold

      candidate_data = JSON.build do |json|
        json.object do
          json.field "entity_a_id", new_entity_id
          json.field "entity_b_id", existing_id
          json.field "similarity_score", sim.score
          json.field "status", "pending"
          json.field "similarity_reasons", sim.reasons
          json.field "frame_id", frame_id if frame_id
        end
      end
      candidate = graph.add_object("merge_candidate", candidate_data)

      begin
        graph.add_relation(candidate.id, new_entity_id, "merge_candidate_for")
      rescue
      end
      begin
        graph.add_relation(candidate.id, existing_id, "merge_candidate_for")
      rescue
      end
    end
  end
end

require "json"
require "time"

module Chronicle::Packs::Research
  # Research Pack behaviors. Ported from upstream packs/research/behaviors.py.
  #
  # paper_ingester                — source.created (kind=research_paper) →
  #                                 Paper + Author(s) + Venue
  # claim_extractor               — paper.created → observation (claims)
  # idea_atom_extractor           — paper.created → idea_atom objects
  # hypothesis_generator          — idea_atom.created (high coherence) →
  #                                 research_direction
  # research_direction_synthesizer — idea_atom.created → merge/synthesize
  #                                 research_direction
  #
  # All v0.1 LLM behaviors are deterministic mock stubs (no API key).
  #
  # Registries (class-level, cleared between fixtures via
  # clear_research_registry):
  #   paper_registry:     source_id → paper_id
  #   venue_registry:     name_lower → venue_id
  #   direction_registry: tag_key → direction_id (hypothesis + synth keys)
  #   idea_atoms_by_paper: paper_id → atom_ids

  # Closed stopword set for _extract_keywords (upstream STOPWORDS). Nested so
  # the DSL pack macro does not treat it as an object type constant.
  module KeywordConstants
    STOPWORDS = Set{
      "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
      "of", "with", "is", "are", "was", "were", "be", "been", "this", "that",
      "we", "our", "paper", "show", "shows", "method", "approach", "propose",
      "proposed", "present", "presented", "using", "used", "can", "also",
      "by", "from", "as", "which", "have", "has", "been", "its", "their",
    }
  end

  # Deterministic idea-atom templates (upstream _mock_idea_atoms templates).
  module IdeaTemplates
    TEMPLATES = [
      "Combining {a} and {b} may yield improvements in {c}.",
      "Applying {a} to {b} problems opens new research directions.",
      "{a} could be extended to handle {b} scenarios.",
      "The relationship between {a} and {b} warrants deeper investigation.",
      "Scaling {a} techniques to {b} remains an open challenge.",
    ]
  end

  # source_id → paper_id.
  class_property paper_registry = {} of String => String
  # name_lower → venue_id.
  class_property venue_registry = {} of String => String
  # tag_key → direction_id (shared by hypothesis_generator and synthesizer).
  class_property direction_registry = {} of String => String
  # paper_id → atom_ids.
  class_property idea_atoms_by_paper = {} of String => Array(String)

  # Reset all registries — call between test fixtures.
  def self.clear_research_registry : Nil
    self.paper_registry = {} of String => String
    self.venue_registry = {} of String => String
    self.direction_registry = {} of String => String
    self.idea_atoms_by_paper = {} of String => Array(String)
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Split an author string by comma, semicolon, or 'and'/'&'.
  def self._parse_authors(author_str : String) : Array(String)
    author_str.split(/[,;]| and | & /).map(&.strip).reject(&.empty?)
  end

  # Extract candidate keywords using TF heuristics (upstream _extract_keywords).
  def self._extract_keywords(text : String, max_kw : Int32 = 6) : Array(String)
    words = text.downcase.scan(/[a-zA-Z]{4,}/).map(&.[0])
    freq = {} of String => Int32
    words.each do |word|
      next if KeywordConstants::STOPWORDS.includes?(word)
      freq[word] = (freq[word]? || 0) + 1
    end
    freq.keys.sort_by! { |word| -freq[word] }.first(max_kw)
  end

  # Deterministic mock claim observations (upstream _mock_claims).
  def self._mock_claims(title : String, abstract_text : String, count : Int32) : Array(String)
    sentences = abstract_text.split(/[.!?]/).map(&.strip).select { |sentence| sentence.size > 20 }
    claims = sentences.first(count)
    if claims.empty?
      claims = ["The paper '#{title}' proposes a novel approach to #{title.downcase[0, 40]}."]
    end
    claims
  end

  # Deterministic mock idea atoms (upstream _mock_idea_atoms).
  def self._mock_idea_atoms(title : String, keywords : Array(String), count : Int32) : Array(String)
    kw = keywords + ["performance", "efficiency", "accuracy", "robustness", "generalization"]
    atoms = [] of String
    limit = Math.min(count, IdeaTemplates::TEMPLATES.size)
    limit.times do |i|
      a = kw[i % kw.size]
      b = kw[(i + 1) % kw.size]
      c = kw[(i + 2) % kw.size]
      template = IdeaTemplates::TEMPLATES[i % IdeaTemplates::TEMPLATES.size]
      atoms << template.gsub("{a}", a).gsub("{b}", b).gsub("{c}", c)
    end
    atoms.first(count)
  end

  # Merge a hash patch onto an object (chronicle's patch_object replaces
  # data; upstream merges — so the merge is explicit here).
  def self._merge_patch(graph : Chronicle::GraphProjection, target : String, changes : Hash(String, JSON::Any)) : Nil
    obj = graph.get_object(target)
    return if obj.nil?
    data = JSON.parse(obj.data).as_h
    changes.each { |key, value| data[key] = value }
    graph.patch_object(target, data.to_json)
  end

  # Ingest a research_paper source into Paper + Author(s) + Venue objects.
  @[Chronicle::Packs::Annotations::Behavior(name: "paper_ingester", on: ["object.created"], where: {"type" => "source"}, creates: ["paper", "author", "venue"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream paper_ingester venue/paper/author branches
  def paper_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ResearchSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless data["kind"]?.try(&.as_s?) == "research_paper"
    return if paper_registry.has_key?(source_id)

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    content = data["content"]?.try(&.as_s?) || ""
    title = meta["title"]?.try(&.as_s?)
    title = content[0, 80] if title.nil? || title.empty?
    title = "Untitled Paper" if title.nil? || title.empty?
    abstract_text = meta["abstract"]?.try(&.as_s?)
    abstract_text = content if abstract_text.nil? || abstract_text.empty?
    abstract_text = "" if abstract_text.nil?
    year = meta["year"]?.try(&.as_i?)
    doi = meta["doi"]?.try(&.as_s?)
    arxiv_id = meta["arxiv_id"]?.try(&.as_s?)
    venue_name = meta["venue"]?.try(&.as_s?)
    venue_name = meta["journal"]?.try(&.as_s?) if venue_name.nil? || venue_name.empty?
    venue_name = meta["conference"]?.try(&.as_s?) if venue_name.nil? || venue_name.empty?
    venue_name = "" if venue_name.nil?
    author_str = meta["authors"]?.try(&.as_s?) || ""
    kw_json = meta["keywords"]?
    keywords =
      if arr = kw_json.try(&.as_a?)
        arr.empty? ? _extract_keywords(abstract_text) : arr.map(&.as_s)
      else
        _extract_keywords(abstract_text)
      end

    # ── Venue ──────────────────────────────────────────────────────────────
    venue_id : String? = nil
    if !venue_name.empty?
      vkey = venue_name.downcase.strip
      if venue_registry.has_key?(vkey)
        venue_id = venue_registry[vkey]
      else
        begin
          lower = venue_name.downcase
          kind = if ["conference", "conf", "workshop", "symposium"].any? { |word| lower.includes?(word) }
                   "conference"
                 else
                   "journal"
                 end
          venue_obj = graph.add_object("venue", {
            "name" => JSON::Any.new(venue_name),
            "kind" => JSON::Any.new(kind),
          }.to_json, actor: "research.paper_ingester")
          venue_id = venue_obj.id
          venue_registry[vkey] = venue_id
        rescue
        end
      end
    end

    # ── Paper ──────────────────────────────────────────────────────────────
    begin
      paper = graph.add_object("paper", {
        "title"     => JSON::Any.new(title),
        "abstract"  => JSON::Any.new(abstract_text[0, 2000]),
        "year"      => JSON::Any.new(year),
        "doi"       => JSON::Any.new(doi),
        "arxiv_id"  => JSON::Any.new(arxiv_id),
        "venue_id"  => JSON::Any.new(venue_id),
        "keywords"  => JSON::Any.new(keywords.map { |k| JSON::Any.new(k) }),
        "source_id" => JSON::Any.new(source_id),
      }.to_json, actor: "research.paper_ingester")
      paper_id = paper.id
      paper_registry[source_id] = paper_id
      graph.add_relation(paper_id, source_id, "derived_from_source", actor: "research.paper_ingester")
    rescue
      return
    end

    if venue_id
      begin
        graph.add_relation(paper_id, venue_id, "published_in", actor: "research.paper_ingester")
      rescue
      end
    end

    # ── Authors ────────────────────────────────────────────────────────────
    if !author_str.empty?
      _parse_authors(author_str).each do |aname|
        author_obj = graph.add_object("author", {
          "name"      => JSON::Any.new(aname),
          "paper_ids" => JSON::Any.new([JSON::Any.new(paper_id)]),
        }.to_json, actor: "research.paper_ingester")
        graph.add_relation(paper_id, author_obj.id, "authored_by", actor: "research.paper_ingester")
      rescue
      end
    end
  end

  # Extract claim observations from a newly ingested paper (deterministic mock).
  @[Chronicle::Packs::Annotations::Behavior(name: "claim_extractor", on: ["object.created"], where: {"type" => "paper"}, creates: ["observation"])]
  def claim_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ResearchSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    paper_id = payload["id"]?.try(&.as_s?)
    return if paper_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    title = data["title"]?.try(&.as_s?) || ""
    abstract_text = data["abstract"]?.try(&.as_s?) || ""
    source_id = data["source_id"]?.try(&.as_s?)

    claims = _mock_claims(title, abstract_text, settings.max_claims_per_paper)
    claims.each do |claim_text|
      obs = graph.add_object("observation", {
        "text"       => JSON::Any.new(claim_text),
        "confidence" => JSON::Any.new(0.75),
        "source_ids" => JSON::Any.new((source_id ? [source_id] : [] of String).map { |id| JSON::Any.new(id) }),
        "category"   => JSON::Any.new("fact"),
        "metadata"   => JSON::Any.new({
          "paper_id"     => JSON::Any.new(paper_id),
          "extracted_by" => JSON::Any.new("claim_extractor"),
        }),
      }.to_json, actor: "research.claim_extractor")
      if source_id
        begin
          graph.add_relation(source_id, obs.id, "grounds", actor: "research.claim_extractor")
        rescue
        end
      end
    rescue
    end
  end

  # Extract atomic research ideas from a paper (deterministic mock).
  @[Chronicle::Packs::Annotations::Behavior(name: "idea_atom_extractor", on: ["object.created"], where: {"type" => "paper"}, creates: ["idea_atom"])]
  def idea_atom_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ResearchSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    paper_id = payload["id"]?.try(&.as_s?)
    return if paper_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    keywords = data["keywords"]?.try(&.as_a?) ? data["keywords"].as_a.map(&.as_s) : [] of String
    title = data["title"]?.try(&.as_s?) || ""
    abstract_text = data["abstract"]?.try(&.as_s?) || ""
    if keywords.empty?
      keywords = _extract_keywords(abstract_text.empty? ? title : abstract_text)
    end

    ideas = _mock_idea_atoms(title, keywords, settings.max_ideas_per_paper)
    atom_ids = [] of String
    ideas.each_with_index do |idea_text, i|
      novelty = (0.4 + (i * 0.08)).clamp(0.0, 0.9).round(2)
      coherence = (0.5 + (i * 0.06)).clamp(0.0, 0.88).round(2)
      begin
        atom = graph.add_object("idea_atom", {
          "text"             => JSON::Any.new(idea_text),
          "source_paper_ids" => JSON::Any.new([JSON::Any.new(paper_id)]),
          "tags"             => JSON::Any.new(keywords.first(3).map { |k| JSON::Any.new(k) }),
          "novelty_score"    => JSON::Any.new(novelty),
          "coherence_score"  => JSON::Any.new(coherence),
        }.to_json, actor: "research.idea_atom_extractor")
        graph.add_relation(paper_id, atom.id, "proposes_idea", actor: "research.idea_atom_extractor")
        atom_ids << atom.id
      rescue
      end
    end
    idea_atoms_by_paper[paper_id] = atom_ids
  end

  # Generate a research direction from a high-coherence idea atom (mock).
  @[Chronicle::Packs::Annotations::Behavior(name: "hypothesis_generator", on: ["object.created"], where: {"type" => "idea_atom"}, creates: ["research_direction"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream hypothesis_generator dedup/merge branches
  def hypothesis_generator(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ResearchSettings) : Nil
    return unless settings.auto_synthesize_directions?

    payload = JSON.parse(event.payload).as_h
    atom_id = payload["id"]?.try(&.as_s?)
    return if atom_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    coherence = data["coherence_score"]?.try(&.as_f?) || 0.0
    return if coherence < settings.min_coherence_for_hypothesis

    tags = data["tags"]?.try(&.as_a?) ? data["tags"].as_a.map(&.as_s) : [] of String
    tag_key = if tags.empty?
                "general"
              else
                tags.first(2).sort.join(":")
              end

    if direction_registry.has_key?(tag_key)
      direction_id = direction_registry[tag_key]
      begin
        existing = graph.get_object(direction_id)
        if existing
          current_ids = JSON.parse(existing.data)["idea_atom_ids"]?.try(&.as_a?) ? JSON.parse(existing.data)["idea_atom_ids"].as_a.map(&.as_s) : [] of String
          if !current_ids.includes?(atom_id)
            _merge_patch(graph, direction_id, {
              "idea_atom_ids" => JSON::Any.new((current_ids + [atom_id]).map { |id| JSON::Any.new(id) }),
            })
          end
        end
      rescue
      end
      begin
        graph.add_relation(atom_id, direction_id, "composes_direction", actor: "research.hypothesis_generator")
      rescue
      end
      return
    end

    idea_text = data["text"]?.try(&.as_s?) || ""
    direction_title = if tags.empty?
                        idea_text[0, 40]
                      else
                        "Research Direction: #{tags.first(2).join(", ")}"
                      end
    summary = "Emerging direction based on idea: '#{idea_text}'. Tags: #{tags.join(", ")}. Synthesized from high-coherence idea atoms."

    begin
      direction = graph.add_object("research_direction", {
        "title"         => JSON::Any.new(direction_title),
        "summary"       => JSON::Any.new(summary),
        "idea_atom_ids" => JSON::Any.new([JSON::Any.new(atom_id)]),
        "status"        => JSON::Any.new("candidate"),
        "confidence"    => JSON::Any.new((coherence * 0.9).round(2)),
      }.to_json, actor: "research.hypothesis_generator")
      direction_registry[tag_key] = direction.id
      graph.add_relation(atom_id, direction.id, "composes_direction", actor: "research.hypothesis_generator")
    rescue
    end
  end

  # Synthesize a research direction when enough idea atoms accumulate (mock).
  @[Chronicle::Packs::Annotations::Behavior(name: "research_direction_synthesizer", on: ["object.created"], where: {"type" => "idea_atom"}, creates: ["research_direction"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream synthesizer dedup/merge branches
  def research_direction_synthesizer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : ResearchSettings) : Nil
    return unless settings.auto_synthesize_directions?

    payload = JSON.parse(event.payload).as_h
    atom_id = payload["id"]?.try(&.as_s?)
    return if atom_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    tags = data["tags"]?.try(&.as_a?) ? data["tags"].as_a.map(&.as_s) : [] of String
    return if tags.empty?

    primary_tag = tags[0].downcase
    synth_key = "synth:#{primary_tag}"

    all_atom_ids_flat = idea_atoms_by_paper.values.flatten
    return if all_atom_ids_flat.size < settings.min_ideas_for_direction

    if direction_registry.has_key?(synth_key)
      direction_id = direction_registry[synth_key]
      begin
        existing = graph.get_object(direction_id)
        if existing
          existing_data = JSON.parse(existing.data)
          current_ids = existing_data["idea_atom_ids"]?.try(&.as_a?) ? existing_data["idea_atom_ids"].as_a.map(&.as_s) : [] of String
          if !current_ids.includes?(atom_id)
            current_conf = existing_data["confidence"]?.try(&.as_f?) || 0.6
            _merge_patch(graph, direction_id, {
              "idea_atom_ids" => JSON::Any.new((current_ids + [atom_id]).map { |id| JSON::Any.new(id) }),
              "confidence"    => JSON::Any.new(Math.min(0.95, current_conf + 0.05).round(2)),
            })
          end
        end
      rescue
      end
      return
    end

    begin
      direction = graph.add_object("research_direction", {
        "title"         => JSON::Any.new("Synthesized Direction: #{_title(primary_tag)} Research"),
        "summary"       => JSON::Any.new("Cross-paper synthesis for '#{primary_tag}' research. Converging signals from #{all_atom_ids_flat.size} idea atoms across multiple papers."),
        "idea_atom_ids" => JSON::Any.new([JSON::Any.new(atom_id)]),
        "status"        => JSON::Any.new("candidate"),
        "confidence"    => JSON::Any.new(0.72),
      }.to_json, actor: "research.research_direction_synthesizer")
      direction_registry[synth_key] = direction.id
      graph.add_relation(atom_id, direction.id, "composes_direction", actor: "research.research_direction_synthesizer")
    rescue
    end
  end

  # Python str.title() equivalent (capitalize each word).
  private def self._title(text : String) : String
    text.split(' ').map { |word| word.empty? ? word : word.capitalize }.join(' ')
  end
end

require "json"

module Chronicle::Packs::Core
  # Three lightweight deterministic behaviors. No LLM calls, no external
  # tools. Ported from upstream packs/core/behaviors.py.
  #
  # 1. observation_extractor — on source.created, extracts key observations
  #    from source content using heuristics (sentence splitting + keyword
  #    scoring), creating `grounds` relations.
  # 2. task_linker — on observation.created, links the observation to any
  #    existing open tasks whose title overlaps significantly, creating
  #    `produces` relations.
  # 3. memory_candidate_proposer — on observation.created, proposes memory
  #    candidates for high-confidence preference/decision/fact/instruction
  #    observations, creating `proposes` relations.
  #
  # The handlers read the event payload as typed Core structs (the pack
  # loader's schema validators already round-tripped the object data) and
  # create new objects via the typed struct's JSON — Crystal's type system
  # replaces the upstream's dict access.

  # ------------------------------------------------------------------ helpers

  # Text-analysis helpers for the deterministic behaviors. Nested module so
  # the DSL's `pack` macro (which assumes every direct constant of Core is a
  # type) doesn't trip over the stopword set.
  module Helpers
    STOPWORDS = Set{
      "a", "an", "the", "and", "or", "but", "in", "on", "at", "to",
      "for", "of", "with", "is", "are", "was", "were", "be", "been",
      "being", "have", "has", "had", "do", "does", "did", "will",
      "would", "could", "should", "may", "might", "shall", "can",
      "this", "that", "these", "those", "it", "its", "i", "we", "you",
      "he", "she", "they", "them", "their", "our", "your", "my", "not",
    }
  end

  # Split text into sentences, trimmed, non-empty, min 10 chars.
  private def self._sentences(text : String) : Array(String)
    text.strip.split(/(?<=[.!?])\s+/).map(&.strip).reject { |sentence| sentence.size < 10 }
  end

  # Lowercase word set, stripping punctuation, ignoring stopwords.
  private def self._word_set(text : String) : Set(String)
    words = text.downcase.scan(/[a-z]+/).map(&.[0])
    words.to_set.reject { |word| Helpers::STOPWORDS.includes?(word) || word.size <= 2 }.to_set
  end

  # Jaccard overlap of word sets between two strings (0.0–1.0).
  private def self._overlap_ratio(a : String, b : String) : Float64
    wa = _word_set(a)
    wb = _word_set(b)
    return 0.0 if wa.empty? || wb.empty?

    (wa & wb).size.to_f / (wa | wb).size
  end

  # Infer an observation category from keyword patterns. Priority order
  # matters: more specific patterns are checked first. Questions are
  # classified first and dropped by the proposer's allow-list.
  private def self._infer_category(text : String) : String?
    text_lower = text.downcase

    return "question" if text.includes?('?')

    return "preference" if ["prefer", "rather", "instead of", "favourite", "favorite"].any? { |keyword| text_lower.includes?(keyword) }

    return "instruction" if ["should", "must", "always", "never", "make sure", "ensure", "please", "requirement", "required"].any? { |keyword| text_lower.includes?(keyword) }

    return "decision" if ["decide", "decided", "agreed", "confirmed", "resolved", "chosen", "chose"].any? { |keyword| text_lower.includes?(keyword) }

    return "action_item" if ["todo", "to-do", "to do", "action item", "follow up", "follow-up"].any? { |keyword| text_lower.includes?(keyword) }

    return "risk" if ["risk", "concern", "problem", "issue", "fail", "failure", "danger", "critical"].any? { |keyword| text_lower.includes?(keyword) }

    return "fact" if ["says", "said", "mentioned", "noted", "stated", "reported", "according"].any? { |keyword| text_lower.includes?(keyword) }

    return "intent" if ["want", "need", "ask", "request"].any? { |keyword| text_lower.includes?(keyword) }

    nil
  end

  # ------------------------------------------------------------------ behaviors

  # Extract key observations from a newly created source object. Uses
  # sentence splitting and heuristic scoring to identify the most
  # informative sentences as observations. Deterministic — no LLM needed.
  @[Chronicle::Packs::Annotations::Behavior(name: "observation_extractor", on: ["object.created"], where: {"type" => "source"}, creates: ["observation"])]
  def observation_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : CoreSettings) : Nil
    payload = JSON.parse(event.payload)
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?

    source = Source.from_json(payload["data"].to_json)
    content = source.content
    return if content.empty?

    sentences = _sentences(content)
    return if sentences.empty?

    word_sets = sentences.map { |sentence| _word_set(sentence) }
    max_words = word_sets.max_of?(&.size) || 1
    # Upstream divides by max word count; a source of punctuation-only
    # sentences would crash Python (ZeroDivisionError) — guard instead.
    max_words = 1 if max_words < 1

    # Score sentences: prefer longer informative sentences.
    scored = sentences.zip(word_sets).sort_by { |_sentence, ws| -(ws.size.to_f / max_words) }

    limit = Math.min(settings.max_observations_per_source, scored.size)
    created = 0
    scored.first(limit).each do |sentence, ws|
      break if created >= limit

      confidence = (ws.size.to_f / max_words).round(2)
      data = {
        text:           sentence,
        confidence:     confidence,
        low_confidence: confidence < settings.observation_min_confidence,
        source_ids:     [source_id],
        frame_id:       source.frame_id,
        category:       _infer_category(sentence),
      }.to_json
      obs = graph.add_object("observation", data)
      graph.add_relation(source_id, obs.id, "grounds")
      created += 1
    end
  end

  # Link a newly created observation to existing open tasks. Computes
  # Jaccard word-overlap between the observation text and each open task's
  # title; if overlap >= threshold, creates a 'produces' relation.
  @[Chronicle::Packs::Annotations::Behavior(name: "task_linker", on: ["object.created"], where: {"type" => "observation"})]
  def task_linker(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : CoreSettings) : Nil
    payload = JSON.parse(event.payload)
    obs_id = payload["id"]?.try(&.as_s?)
    return if obs_id.nil?

    observation = Observation.from_json(payload["data"].to_json)
    return if observation.text.empty?

    open_tasks = graph.objects(type: "task").select do |task|
      Task.from_json(task.data).status.in?({"candidate", "active"})
    end

    threshold = settings.task_link_similarity_threshold
    open_tasks.each do |task|
      task_title = Task.from_json(task.data).title
      next if task_title.empty?
      next unless _overlap_ratio(observation.text, task_title) >= threshold

      begin
        graph.add_relation(obs_id, task.id, "produces")
      rescue
        # Relation may already exist
      end
    end
  end

  # Propose a memory_candidate for durable high-confidence observations.
  # Only preference/decision/fact/instruction observations with
  # confidence >= 0.7 become candidates; Memory Gateway decides whether
  # to actually store them.
  @[Chronicle::Packs::Annotations::Behavior(name: "memory_candidate_proposer", on: ["object.created"], where: {"type" => "observation"}, creates: ["memory_candidate"])]
  def memory_candidate_proposer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : CoreSettings) : Nil
    payload = JSON.parse(event.payload)
    obs_id = payload["id"]?.try(&.as_s?)
    return if obs_id.nil?

    observation = Observation.from_json(payload["data"].to_json)
    category = observation.category
    return unless category.in?({"preference", "decision", "fact", "instruction"})
    return if observation.confidence < 0.7
    return if observation.text.empty?

    data = {
      text:            observation.text,
      confidence:      observation.confidence,
      source_ids:      observation.source_ids,
      observation_ids: [obs_id],
      category:        category,
      accepted:        settings.auto_accept_memory_candidates?,
      frame_id:        observation.frame_id,
    }.to_json
    candidate = graph.add_object("memory_candidate", data)

    graph.add_relation(obs_id, candidate.id, "proposes")
  end
end

require "json"

module Chronicle::Packs::SemanticExtraction
  # The standard extraction facets and their typed annotation bodies.
  # Ported from upstream packs/semantic_extraction/facets.py.

  # Nested so the DSL pack macro (which assumes direct module constants are
  # types) can enumerate the surface.
  module Facets
    STANDARD_FACETS        = ["entity_mention", "assertion", "question", "idea", "event_mention", "relation_mention", "preference_expression", "temporal_expression", "quantity_mention", "topic_tag"]
    DEFAULT_EAGER_FLOOR    = ["assertion", "entity_mention", "preference_expression", "question", "temporal_expression"]
    V1_IMPLEMENTED_FACETS  = ["assertion", "entity_mention", "preference_expression", "question", "temporal_expression", "topic_tag"]
    LLM_IMPLEMENTED_FACETS = ["assertion", "entity_mention", "event_mention", "preference_expression", "relation_mention"]
    LLM_UPGRADE_FACETS     = ["event_mention", "relation_mention"]
  end

  # ---- facet body schemas -------------------------------------------------

  record EntityMentionBody,
    text : String,
    kind : String,
    normalized : String do
    include JSON::Serializable
  end

  record AssertionBody,
    text : String do
    include JSON::Serializable
  end

  record QuestionBody,
    text : String do
    include JSON::Serializable
  end

  record PreferenceExpressionBody,
    text : String,
    cue : String do
    include JSON::Serializable
  end

  record TemporalExpressionBody,
    text : String,
    normalized : String,
    precision : String do
    include JSON::Serializable
  end

  record TopicTagBody,
    tag : String,
    occurrences : Int32 do
    include JSON::Serializable
  end

  record RelationMentionBody,
    text : String,
    subject : String,
    predicate : String,
    object : String do
    include JSON::Serializable
  end

  record EventMentionBody,
    text : String,
    name : String,
    participants : Array(String) = [] of String,
    when : String? = nil do
    include JSON::Serializable
  end

  # Type-check one annotation body against its facet schema. Facets without
  # a shipped schema pass through unchanged.
  def self.validate_body(facet : String, body : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    case facet
    when "entity_mention"
      JSON.parse(EntityMentionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "assertion"
      JSON.parse(AssertionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "question"
      JSON.parse(QuestionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "preference_expression"
      JSON.parse(PreferenceExpressionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "temporal_expression"
      JSON.parse(TemporalExpressionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "topic_tag"
      JSON.parse(TopicTagBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "relation_mention"
      JSON.parse(RelationMentionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    when "event_mention"
      JSON.parse(EventMentionBody.from_json(JSON::Any.new(body).to_json).to_json).as_h
    else
      body
    end
  end
end

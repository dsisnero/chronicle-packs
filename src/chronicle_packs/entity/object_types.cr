require "json"

module Chronicle::Packs::Entity
  # Entity object types. Ported from upstream packs/entity/object_types.py.
  # Entity is the canonical record; EntityMention provides provenance;
  # dedup is via MergeCandidate + MergeDecision (never auto-merge).

  # A canonical, deduped representation of a real-world entity.
  @[Chronicle::Packs::Annotations::ObjectType(name: "entity")]
  struct Entity
    include JSON::Serializable

    getter name : String
    getter entity_type : String = "other"
    getter aliases : Array(String) = [] of String
    getter identifiers : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter confidence : Float64 = 0.8
    getter description : String = ""
    getter source_ids : Array(String) = [] of String
    getter merged_from_ids : Array(String) = [] of String
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A reference to an entity found in a source.
  @[Chronicle::Packs::Annotations::ObjectType(name: "entity_mention")]
  struct EntityMention
    include JSON::Serializable

    getter text : String
    getter source_id : String
    getter entity_id : String? = nil
    getter entity_type_hint : String? = nil
    getter confidence : Float64 = 0.7
    getter context_snippet : String = ""
    getter extraction_method : String = "heuristic"
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Two entities that may be the same, pending a dedup decision.
  @[Chronicle::Packs::Annotations::ObjectType(name: "merge_candidate")]
  struct MergeCandidate
    include JSON::Serializable

    getter entity_a_id : String
    getter entity_b_id : String
    getter similarity_score : Float64
    getter status : String = "pending"
    getter similarity_reasons : Array(String) = [] of String
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A decision on a MergeCandidate — merge, reject, or defer.
  @[Chronicle::Packs::Annotations::ObjectType(name: "merge_decision")]
  struct MergeDecision
    include JSON::Serializable

    getter merge_candidate_id : String
    getter decision : String
    getter surviving_entity_id : String? = nil
    getter rationale : String = ""
    getter decided_by : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

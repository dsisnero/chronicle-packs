require "json"

module Chronicle::Packs::Core
  # Seven universal primitives that form the shared substrate for all
  # domain packs. These are intentionally minimal; domain-specific fields
  # live in domain packs. Ported from upstream packs/core/object_types.py.
  #
  # Design rule: observation-first. Observations are weaker than claims —
  # they record "the system noticed this" without asserting truth. person,
  # company, claim, evidence, document do NOT belong here.

  # Something the system received or observed from the outside world.
  @[Chronicle::Packs::Annotations::ObjectType(name: "source")]
  struct Source
    include JSON::Serializable

    getter kind : String
    getter content : String = ""
    getter url : String? = nil
    getter channel : String? = nil
    getter sender_ref : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A source-grounded thing the system noticed.
  @[Chronicle::Packs::Annotations::ObjectType(name: "observation")]
  struct Observation
    include JSON::Serializable

    getter text : String
    getter confidence : Float64 = 0.8
    getter? low_confidence : Bool = false
    getter source_ids : Array(String) = [] of String
    getter frame_id : String? = nil
    getter category : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A minimal unit of work. Deliberately underpowered in Core — Team/Ops
  # Pack extends it with assignments, milestones, and workload.
  @[Chronicle::Packs::Annotations::ObjectType(name: "task")]
  struct Task
    include JSON::Serializable

    getter title : String
    getter description : String = ""
    getter status : String = "candidate"
    getter priority : String = "medium"
    getter source_observation_ids : Array(String) = [] of String
    getter owner_ref : String? = nil
    getter due_at : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A proposed or executed operation. Actions flow through Tool Gateway
  # before execution — the model proposes, the runtime authorizes.
  @[Chronicle::Packs::Annotations::ObjectType(name: "action")]
  struct Action
    include JSON::Serializable

    getter kind : String
    getter description : String
    getter status : String = "proposed"
    getter proposed_by : String? = nil
    getter input_data : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter result : String? = nil
    getter error : String? = nil
    getter executed_at : String? = nil
    getter credential_ref : String? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter risk_class : String = "medium"
  end

  # A durable output produced by the assistant (memo, draft, report, ...).
  @[Chronicle::Packs::Annotations::ObjectType(name: "artifact")]
  struct Artifact
    include JSON::Serializable

    getter kind : String
    getter title : String
    getter content : String = ""
    getter format : String = "markdown"
    getter source_ids : Array(String) = [] of String
    getter task_ids : Array(String) = [] of String
    getter observation_ids : Array(String) = [] of String
    getter status : String = "draft"
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Something that might be worth remembering. Memory Gateway decides
  # whether to accept it; Core only provides the candidate primitive.
  @[Chronicle::Packs::Annotations::ObjectType(name: "memory_candidate")]
  struct MemoryCandidate
    include JSON::Serializable

    getter text : String
    getter confidence : Float64 = 0.7
    getter source_ids : Array(String) = [] of String
    getter observation_ids : Array(String) = [] of String
    getter category : String? = nil
    getter subject_ref : String? = nil
    getter? accepted : Bool = false
    getter evaluation_id : String? = nil
    getter frame_id : String? = nil
  end

  # A judgment about an object, action, task, artifact, or memory candidate.
  @[Chronicle::Packs::Annotations::ObjectType(name: "evaluation")]
  struct Evaluation
    include JSON::Serializable

    getter subject_id : String
    getter subject_type : String
    getter judgment : String
    getter rationale : String = ""
    getter evaluator : String? = nil
    getter score : Float64? = nil
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end

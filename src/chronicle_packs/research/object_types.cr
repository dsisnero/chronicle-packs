require "json"

module Chronicle::Packs::Research
  # Research Pack object types. Ported from upstream packs/research/
  # object_types.py. 9 object types for scientific knowledge tracking.

  # Closed Literal sets for the research surface (AGENTS.md: closed string
  # sets are enums; non-flags enums round-trip via the underscore name).

  # Venue.kind — upstream Literal["journal", "conference", "workshop",
  # "preprint", "other"].
  enum VenueKind
    Journal
    Conference
    Workshop
    Preprint
    Other
  end

  # ResearchDirection.status — upstream Literal["candidate", "active",
  # "published", "abandoned"].
  enum DirectionStatus
    Candidate
    Active
    Published
    Abandoned
  end

  # Experiment.status — upstream Literal["proposed", "running", "completed",
  # "failed", "abandoned"].
  enum ExperimentStatus
    Proposed
    Running
    Completed
    Failed
    Abandoned
  end

  # A research paper with title, abstract, authors, venue, and metadata.
  @[Chronicle::Packs::Annotations::ObjectType(name: "paper", description: "A research paper with title, abstract, authors, venue, and metadata.")]
  struct Paper
    include JSON::Serializable

    getter title : String
    getter abstract : String = ""
    getter year : Int32? = nil
    getter doi : String? = nil
    getter arxiv_id : String? = nil
    getter venue_id : String? = nil
    getter author_ids : Array(String) = [] of String
    getter keywords : Array(String) = [] of String
    getter citation_count : Int32 = 0
    getter source_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A research author with affiliation and paper list.
  @[Chronicle::Packs::Annotations::ObjectType(name: "author", description: "A research author with affiliation and paper list.")]
  struct Author
    include JSON::Serializable

    getter name : String
    getter email : String? = nil
    getter affiliation : String? = nil
    getter semantic_scholar_id : String? = nil
    getter h_index : Int32? = nil
    getter paper_ids : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A publication venue: journal, conference, workshop, or preprint server.
  @[Chronicle::Packs::Annotations::ObjectType(name: "venue", description: "A publication venue: journal, conference, workshop, or preprint server.")]
  struct Venue
    include JSON::Serializable

    getter name : String
    getter kind : VenueKind = VenueKind::Other
    getter abbreviation : String? = nil
    getter impact_factor : Float64? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A research method or algorithm referenced in one or more papers.
  @[Chronicle::Packs::Annotations::ObjectType(name: "method", description: "A research method or algorithm referenced in one or more papers.")]
  struct Method
    include JSON::Serializable

    getter name : String
    getter description : String = ""
    getter paper_ids : Array(String) = [] of String
    getter tags : Array(String) = [] of String
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A benchmark task with metric and state-of-the-art tracking.
  @[Chronicle::Packs::Annotations::ObjectType(name: "benchmark", description: "A benchmark task with metric and state-of-the-art tracking.")]
  struct Benchmark
    include JSON::Serializable

    getter name : String
    getter task : String = ""
    getter metric : String = ""
    getter sota_value : Float64? = nil
    getter sota_paper_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A research dataset referenced in papers.
  @[Chronicle::Packs::Annotations::ObjectType(name: "dataset", description: "A research dataset referenced in papers.")]
  struct Dataset
    include JSON::Serializable

    getter name : String
    getter description : String = ""
    getter size : String? = nil
    getter domain : String? = nil
    getter url : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # An atomic research idea distilled from papers.
  @[Chronicle::Packs::Annotations::ObjectType(name: "idea_atom", description: "An atomic research idea distilled from papers.")]
  struct IdeaAtom
    include JSON::Serializable

    getter text : String
    getter source_paper_ids : Array(String) = [] of String
    getter tags : Array(String) = [] of String
    getter novelty_score : Float64 = 0.5
    getter coherence_score : Float64 = 0.5
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @text : String,
      @source_paper_ids : Array(String) = [] of String,
      @tags : Array(String) = [] of String,
      @novelty_score : Float64 = 0.5,
      @coherence_score : Float64 = 0.5,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end

  # A synthesized research direction from multiple idea atoms.
  @[Chronicle::Packs::Annotations::ObjectType(name: "research_direction", description: "A synthesized research direction from multiple idea atoms.")]
  struct ResearchDirection
    include JSON::Serializable

    getter title : String
    getter summary : String = ""
    getter idea_atom_ids : Array(String) = [] of String
    getter status : DirectionStatus = DirectionStatus::Candidate
    getter confidence : Float64 = 0.6
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A proposed or running research experiment.
  @[Chronicle::Packs::Annotations::ObjectType(name: "experiment", description: "A proposed or running research experiment.")]
  struct Experiment
    include JSON::Serializable

    getter title : String
    getter hypothesis : String = ""
    getter direction_id : String? = nil
    getter status : ExperimentStatus = ExperimentStatus::Proposed
    getter result_summary : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @title : String,
      @hypothesis : String = "",
      @direction_id : String? = nil,
      @status : ExperimentStatus = ExperimentStatus::Proposed,
      @result_summary : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end
